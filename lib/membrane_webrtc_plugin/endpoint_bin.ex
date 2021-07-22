defmodule Membrane.WebRTC.EndpointBin do
  @moduledoc """
  Module responsible for interacting with a WebRTC peer.

  To send or receive tracks from a WebRTC peer, specify them with
  `:inbound_tracks` and `:outbound_tracks` options, and link corresponding
  `:input` and `:output` pads with ids matching the declared tracks' ids.

  The tracks can be manipulated by sending `t:track_message/0`.

  To initiate or modify the connection, the bin sends and expects to receive
  `t:signal_message/0`.
  """
  use Membrane.Bin
  use Bunch

  alias ExSDP.{Attribute.SSRC, Media}
  alias Membrane.WebRTC.{SDP, Track}

  require Membrane.Logger

  @type signal_message ::
          {:signal, {:sdp_offer | :sdp_answer, String.t()} | {:candidate, String.t()}}

  @type track_message :: alter_tracks_message() | enable_track_message() | disable_track_message()

  @typedoc """
  Message that adds or removes tracks.
  """
  @type alter_tracks_message :: {:add_tracks, [Track.t()]} | {:remove_tracks, [Track.id()]}

  @typedoc """
  Message that enables track.
  """
  @type enable_track_message :: {:disable_track, Track.id()}

  @typedoc """
  Message that disables track.
  """
  @type disable_track_message :: {:disable_track, Track.id()}

  def_options inbound_tracks: [
                spec: [Membrane.WebRTC.Track.t()],
                default: [],
                description: "List of initial inbound tracks"
              ],
              outbound_tracks: [
                spec: [Membrane.WebRTC.Track.t()],
                default: [],
                description: "List of initial outbound tracks"
              ],
              stun_servers: [
                type: :list,
                spec: [ExLibnice.stun_server()],
                default: [],
                description: "List of stun servers"
              ],
              turn_servers: [
                type: :list,
                spec: [ExLibnice.relay_info()],
                default: [],
                description: "List of turn servers"
              ],
              port_range: [
                spec: Range.t(),
                default: 0..0,
                description: "Port range to be used by `Membrane.ICE.Bin`"
              ],
              handshake_opts: [
                type: :list,
                spec: Keyword.t(),
                default: [],
                description: """
                Keyword list with options for handshake module. For more information please
                refer to `Membrane.ICE.Bin`
                """
              ],
              video_codecs: [
                type: :list,
                spec: [ExSDP.Attribute.t()],
                default: [],
                description: "Video codecs that will be passed for SDP offer generation"
              ],
              audio_codecs: [
                type: :list,
                spec: [ExSDP.Attribute.t()],
                default: [],
                description: "Audio codecs that will be passed for SDP offer generation"
              ],
              use_default_codecs: [
                spec: [:audio | :video],
                default: [:audio, :video],
                description:
                  "Defines whether to use default codecs or not. Default codecs are those required by WebRTC standard - OPUS, VP8 and H264"
              ],
              log_metadata: [
                spec: :list,
                spec: Keyword.t(),
                default: [],
                description: "Logger metadata used for endpoint bin and all its descendants"
              ]

  def_input_pad :input,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      encoding: [
        spec: :OPUS | :H264,
        description: "Track encoding"
      ],
      track_enabled: [
        spec: boolean(),
        default: true,
        description: "Enable or disable track"
      ]
    ]

  def_output_pad :output,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      track_enabled: [
        spec: boolean(),
        default: true,
        description: "Enable or disable track"
      ],
      packet_filters: [
        spec: [Membrane.RTP.SessionBin.packet_filter_t()],
        default: [],
        description: "List of packet filters that will be applied to the SessionBin's output pad"
      ],
      extensions: [
        spec: [Membrane.RTP.SessionBin.extension_t()],
        default: [],
        description: "List of tuples representing rtp extensions"
      ]
    ]

  @impl true
  def handle_init(opts) do
    children = %{
      ice: %Membrane.ICE.Bin{
        stun_servers: opts.stun_servers,
        turn_servers: opts.turn_servers,
        port_range: opts.port_range,
        controlling_mode: true,
        handshake_module: Membrane.DTLS.Handshake,
        handshake_opts: opts.handshake_opts
      },
      rtp: %Membrane.RTP.SessionBin{secure?: true},
      ice_funnel: Membrane.Funnel
    }

    rtp_input_ref = make_ref()

    links = [
      link(:rtp)
      |> via_out(Pad.ref(:rtcp_output, rtp_input_ref))
      |> to(:ice_funnel),
      link(:ice)
      |> via_out(Pad.ref(:output, 1))
      |> via_in(Pad.ref(:rtp_input, rtp_input_ref))
      |> to(:rtp),
      link(:ice_funnel)
      |> via_out(:output)
      |> via_in(Pad.ref(:input, 1))
      |> to(:ice)
    ]

    spec = %ParentSpec{
      children: children,
      links: links
    }

    state =
      %{
        inbound_tracks: %{},
        outbound_tracks: %{},
        audio_codecs: opts.audio_codecs,
        video_codecs: opts.video_codecs,
        use_default_codecs: opts.use_default_codecs,
        candidates: [],
        candidate_gathering_state: nil,
        dtls_fingerprint: nil,
        trackid_to_ssrc: []
      }
      |> add_tracks(:inbound_tracks, opts.inbound_tracks)
      |> add_tracks(:outbound_tracks, opts.outbound_tracks)

    {{:ok, spec: spec, log_metadata: opts.log_metadata}, state}
  end

  defp hex_dump(digest_str) do
    digest_str
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &Base.encode16(<<&1>>))
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, ctx, state) do
    # Membrane.Logger.info("input add: #{inspect track_id} \n tracks: #{inspect state.outbound_tracks}")
    %{encoding: encoding} = ctx.options
    %Track{ssrc: ssrc} = Map.fetch!(state.outbound_tracks, track_id)
    %{track_enabled: track_enabled} = ctx.pads[pad].options

    encoding_specific_links =
      case encoding do
        :H264 -> &to(&1, {:h264_parser, ssrc}, %Membrane.H264.FFmpeg.Parser{alignment: :nal})
        _other -> & &1
      end

    links = [
      link_bin_input(pad)
      |> pipe_fun(encoding_specific_links)
      |> to({:track_filter, track_id}, %Membrane.WebRTC.TrackFilter{enabled: track_enabled})
      |> via_in(Pad.ref(:input, ssrc))
      |> to(:rtp)
      |> via_out(Pad.ref(:rtp_output, ssrc), options: [encoding: encoding])
      |> to(:ice_funnel)
    ]

    {{:ok, spec: %ParentSpec{links: links}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, track_id) = pad, ctx, state) do
    %Track{ssrc: ssrc, encoding: encoding} = Map.fetch!(state.inbound_tracks, track_id)
    [%{clock_rate: clock_rate} | _ ] = for mapping <- Map.values(state.mappings), mapping.track_id==track_id, do: mapping


    %{track_enabled: track_enabled, extensions: extensions, packet_filters: packet_filters} =
      ctx.pads[pad].options

    spec = %ParentSpec{
      children: %{
        {:track_filter, track_id} => %Membrane.WebRTC.TrackFilter{enabled: track_enabled}
      },
      links: [
        link(:rtp)
        |> via_out(Pad.ref(:output, ssrc),
          options: [encoding: encoding, packet_filters: packet_filters, extensions: extensions]
        )
        |> to({:track_filter, track_id})
        |> via_out(:output)
        |> to_bin_output(pad)
      ]
    }

    {{:ok, spec: spec}, state}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, pt}, _from, _ctx, state) do
    %{encoding_name: encoding} = Map.get(state.mappings,pt)
    mid = Map.fetch!(state.ssrc_to_mid, ssrc)
    track = Map.fetch!(state.inbound_tracks, mid)
    track = %Track{track | ssrc: ssrc, encoding: encoding}
    state = put_in(state, [:inbound_tracks, track.id], track)
    {{:ok, notify: {:new_track, track.id, encoding}}, state}
  end

  @impl true
  def handle_notification({:handshake_init_data, _component_id, fingerprint}, _from, _ctx, state) do
    {:ok, %{state | dtls_fingerprint: {:sha256, hex_dump(fingerprint)}}}
  end

  @impl true
  def handle_notification({:local_credentials, credentials}, _from, _ctx, state) do
    [ice_ufrag, ice_pwd] = String.split(credentials, " ")

    state = Map.put(state,:ice, %{ufrag: ice_ufrag, pwd: ice_pwd})


    offer =
      SDP.create_offer(
        inbound_tracks: Map.values(state.outbound_tracks),
        outbound_tracks: Map.values(%{}),
        video_codecs: state.video_codecs,
        audio_codecs: state.audio_codecs,
        use_default_codecs: state.use_default_codecs,
        ice_ufrag: ice_ufrag,
        ice_pwd: ice_pwd,
        fingerprint: state.dtls_fingerprint
      )

    only_media = offer.media
    only_media_offer = Enum.reduce(only_media,"", & &2 <> "m=" <> to_string(&1) <> "\r\n")

    actions = [notify: {:signal, {:sdp_offer, only_media_offer}}]

    {{:ok,actions}, state}
  end


  @impl true
  def handle_notification({:new_candidate_full, cand}, _from, _ctx, state) do
    state = Map.update!(state, :candidates, &[cand | &1])
    {{:ok, notify_candidates([cand])}, state}
  end

  @impl true
  def handle_notification(:candidate_gathering_done, _from, _ctx, state) do
    {:ok, %{state | candidate_gathering_state: :done}}
  end

  @impl true
  def handle_notification({:vad, _val} = msg, _from, _ctx, state) do
    {{:ok, notify: msg}, state}
  end

  @impl true
  def handle_notification(_notification, _from, _ctx, state) do
    {:ok, state}
  end

  defp add_mappings_to_state(tracks_mappings,state) do
    mappings = Enum.reduce(tracks_mappings, %{}, & Map.put(&2,&1.payload_type, &1))
    Map.put(state, :mappings, mappings)
  end

  defp get_inbound_tracks_from_sdp(sdp) do
    send_only_sdp_media = SDP.filter_sdp_media(sdp,&(:sendonly in &1.attributes))

    stream_id = Track.stream_id()

    tracks_mappings = Enum.map(send_only_sdp_media, & SDP.create_track_from_sdp_media(&1,stream_id))

    inbound_tracks = Enum.map(tracks_mappings, & &1.track)

    mappings = Enum.map(tracks_mappings, & &1.mapping)

    {inbound_tracks, mappings}
  end

  defp handle_outbound_tracks_from_sdp(sdp,state) do
    recv_only_sdp_media = SDP.filter_sdp_media(sdp,&(:recvonly in &1.attributes))
    send_only_sdp_media = SDP.filter_sdp_media(sdp,&(:sendonly in &1.attributes))
    tracks = Map.values(state.outbound_tracks)

    audios = Enum.filter(tracks, & &1.type === :audio)
    videos = Enum.filter(tracks, & &1.type === :video)

    media = send_only_sdp_media ++ SDP.add_ssrc_to_media_from_tracks(recv_only_sdp_media,audios,videos,[])
    %ExSDP{ sdp | media: media}
  end

  defp new_tracks?(inbound_tracks,state) do
    # Membrane.Logger.info("inbound_tracks: #{inspect inbound_tracks}")
    # Membrane.Logger.info("state: #{inspect Map.values(state.inbound_tracks)}")
    state_tracks = Map.values(state.inbound_tracks) |> Enum.reduce([],& &2 ++ [&1.ssrc]) |> List.flatten()

    Enum.reduce(inbound_tracks,[], & &2 ++ &1.ssrc) |> Enum.map(& &1 in state_tracks) |> Enum.all?()
  end

  defp set_inbound_tracks(tracks,state) do
    tracks = Map.new(tracks, &{&1.id,&1})
    Map.put(state, :inbound_tracks, tracks)
  end

  defp set_ssrc_to_mid(inbound_tracks,state) do
    ssrc_to_mid =
      inbound_tracks
      |> Enum.map(fn track ->
        mid = track.id
        [ssrc | _ ] = track.ssrc
        {ssrc,mid}
      end)
      |> Enum.into(%{})
      Map.put(state,:ssrc_to_mid,ssrc_to_mid)
  end

  defp new_tracks_change(tracks,mappings,state) do

    state = add_mappings_to_state(mappings, state)

    state = set_inbound_tracks(tracks,state)

    state = set_ssrc_to_mid(tracks,state)

    actions = [notify: {:link_tracks, tracks}]
    {actions,state}
  end

  @impl true
  def handle_other({:signal, {:sdp_offer, sdp}}, _ctx, state) do
    {:ok, sdp} = sdp |> ExSDP.parse()

    {inbound_tracks,mappings} = get_inbound_tracks_from_sdp(sdp)

    {link_notify, state} = case not new_tracks?(inbound_tracks,state) do
      true -> new_tracks_change(inbound_tracks,mappings,state)
      false -> {[],state}
    end

    inbound_ssrcs = Enum.reduce(state.inbound_tracks, [], & &2 ++ elem(&1,1).ssrc)

    opts = %{ice: state.ice,fingerprint: state.dtls_fingerprint, ssrcs: inbound_ssrcs}

    sdp = handle_outbound_tracks_from_sdp(sdp,state)

    answer = SDP.prepare_answer_from_offer(sdp,opts)


    {actions, state} =
      withl tracks_check: true <- state.inbound_tracks != %{} or state.outbound_tracks != %{},
            candidate_gathering_check: nil <- state.candidate_gathering_state do
        {[forward: [ice: :gather_candidates]], %{state | candidate_gathering_state: :in_progress}}
      else
        tracks_check: _ -> {[], state}
        candidate_gathering_check: _ -> {notify_candidates(state.candidates), state}
      end


    actions = actions ++ link_notify

    actions = [notify: {:signal, {:sdp_answer, to_string(answer)}}] ++  set_remote_credentials(sdp) ++ actions

    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:signal, {:candidate, candidate}}, _ctx, state) do
    {{:ok, forward: {:ice, {:set_remote_candidate, "a=" <> candidate, 1}}}, state}
  end

  @impl true
  def handle_other({:change_trackid_to_ssrc, trackid_to_ssrc}, _ctx, state) do
    state = Map.put(state,:trackid_to_ssrc,trackid_to_ssrc)
    {:ok, state}
  end


  @impl true
  def handle_other({:add_tracks, tracks}, _ctx, state) do
    state = add_tracks(state, :outbound_tracks, tracks)
    {{:ok, forward: {:ice, :restart_stream}}, state}
  end

  @impl true
  def handle_other({:remove_tracks, tracks_ids}, _ctx, state) do
    state = Map.update!(state, :outbound_tracks, &Map.drop(&1, tracks_ids))
    {{:ok, forward: {:ice, :restart_stream}}, state}
  end

  @impl true
  def handle_other({:enable_track, track_id}, _ctx, state) do
    {{:ok, forward: {{:track_filter, track_id}, :enable_track}}, state}
  end

  @impl true
  def handle_other({:disable_track, track_id}, _ctx, state) do
    {{:ok, forward: {{:track_filter, track_id}, :disable_track}}, state}
  end

  defp add_tracks(state, direction, tracks) do
    tracks =
      case direction do
        :outbound_tracks ->
          Track.add_ssrc(
            tracks,
            Map.values(state.inbound_tracks) ++ Map.values(state.outbound_tracks)
          )

        :inbound_tracks ->
          tracks
      end

    tracks = Map.new(tracks, &{&1.id, &1})
    Map.update!(state, direction, &Map.merge(&1, tracks))
  end

  defp notify_candidates(candidates) do
    Enum.flat_map(candidates, fn cand ->
      [notify: {:signal, {:candidate, cand, 0}}]
    end)
  end

  defp set_remote_credentials(sdp) do
    case List.first(sdp.media) do
      nil ->
        []

      media ->
        {_key, ice_ufrag} = Media.get_attribute(media, :ice_ufrag)
        {_key, ice_pwd} = Media.get_attribute(media, :ice_pwd)
        remote_credentials = ice_ufrag <> " " <> ice_pwd
        [forward: {:ice, {:set_remote_credentials, remote_credentials}}]
    end
  end

  # TODO: remove once updated to Elixir 1.12
  defp pipe_fun(term, fun), do: fun.(term)
end

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

  alias ExSDP.Media
  alias ExSDP.Attribute.{FMTP, RTPMapping}
  alias Membrane.WebRTC.{SDP, Track}

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
              filter_codecs: [
                spec: ({RTPMapping, FMTP} -> boolean()),
                default: &SDP.filter_mappings(&1),
                description: "Defines function which will filter SDP m-line by codecs"
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
        handshake_opts: opts.handshake_opts,
        log_metadata: opts.log_metadata
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
        candidates: [],
        candidate_gathering_state: nil,
        dtls_fingerprint: nil,
        ssrc_to_track_id: %{},
        filter_codecs: opts.filter_codecs,
        ice: %{restarting?: false, waiting_restart?: false, pwd: nil, ufrag: nil}
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
    %{encoding: encoding} = ctx.options
    %Track{ssrc: ssrc, rtp_mapping: mapping} = Map.fetch!(state.outbound_tracks, track_id)
    %{track_enabled: track_enabled} = ctx.pads[pad].options

    options = [
      encoding: encoding,
      clock_rate: mapping.clock_rate,
      payload_type: mapping.payload_type
    ]

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
      |> via_out(Pad.ref(:rtp_output, ssrc), options: options)
      |> to(:ice_funnel)
    ]

    {{:ok, spec: %ParentSpec{links: links}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, track_id) = pad, ctx, state) do
    %Track{ssrc: ssrc, encoding: encoding, rtp_mapping: rtp_mapping} =
      track = Map.fetch!(state.inbound_tracks, track_id)

    %{track_enabled: track_enabled, extensions: extensions, packet_filters: packet_filters} =
      ctx.pads[pad].options

    spec = %ParentSpec{
      children: %{
        {:track_filter, track_id} => %Membrane.WebRTC.TrackFilter{enabled: track_enabled}
      },
      links: [
        link(:rtp)
        |> via_out(Pad.ref(:output, ssrc),
          options: [
            encoding: encoding,
            packet_filters: packet_filters,
            extensions: extensions,
            clock_rate: rtp_mapping.clock_rate
          ]
        )
        |> to({:track_filter, track_id})
        |> via_out(:output)
        |> to_bin_output(pad)
      ]
    }

    state = put_in(state, [:inbound_tracks, track_id], %{track | status: :linked})

    {{:ok, spec: spec}, state}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, _pt}, _from, _ctx, state) do
    track_id = Map.fetch!(state.ssrc_to_track_id, ssrc)
    track = Map.fetch!(state.inbound_tracks, track_id)
    track = %Track{track | ssrc: ssrc}
    state = put_in(state, [:inbound_tracks, track.id], track)
    {{:ok, notify: {:new_track, track.id, track.encoding}}, state}
  end

  @impl true
  def handle_notification({:handshake_init_data, _component_id, fingerprint}, _from, _ctx, state) do
    {:ok, %{state | dtls_fingerprint: {:sha256, hex_dump(fingerprint)}}}
  end

  @impl true
  def handle_notification({:local_credentials, credentials}, _from, _ctx, state) do
    [ice_ufrag, ice_pwd] = String.split(credentials, " ")

    state = %{state | ice: %{state.ice | ufrag: ice_ufrag, pwd: ice_pwd, restarting?: true}}

    tracks_types =
      Map.values(state.outbound_tracks)
      |> Enum.filter(&(&1.status != :none))
      |> Enum.map(& &1.type)

    actions = [notify: {:signal, {:offer_data, tracks_types}}]

    {{:ok, actions}, state}
    # {:ok, state}
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
  def handle_notification(:connection_failed, _from, _ctx, state) do
    state = %{state | ice: %{state.ice | restarting?: false}}
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  def handle_notification(:connection_ready, _from, _ctx, state) when state.ice.restarting? do
    outbound_tracks = Map.values(state.outbound_tracks) |> Enum.filter(&(&1.status != :none))

    get_encoding = fn track_id -> Map.get(state.outbound_tracks, track_id).encoding end

    outbound_tracks_id_to_link =
      outbound_tracks
      |> Enum.filter(&(&1.status === :ready))
      |> Enum.map(& &1.id)

    tracks_id_to_link_with_encoding =
      outbound_tracks_id_to_link
      |> Enum.map(&{&1, get_encoding.(&1)})

    negotiations = [notify: {:negotiation_done, tracks_id_to_link_with_encoding}]

    state = %{state | outbound_tracks: change_tracks_status(state, :ready, :linked)}

    state = %{state | ice: %{state.ice | restarting?: false}}

    {restart_action, state} = maybe_restart_ice(state)

    actions = negotiations ++ restart_action

    {{:ok, actions}, state}
  end

  @impl true
  def handle_notification(:connection_ready, _from, _ctx, state) when not state.ice.restarting? do
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  def handle_notification(_notification, _from, _ctx, state), do: {:ok, state}

  defp change_tracks_status(state, prev_status, new_status) do
    change_ready_tracks = fn track ->
      if track.status === prev_status, do: %{track | status: new_status}, else: track
    end

    state.outbound_tracks
    |> Map.values()
    |> Map.new(fn track ->
      {track.id, change_ready_tracks.(track)}
    end)
  end

  defp get_inbound_tracks_from_sdp(sdp, state) do
    inbound_tracks = SDP.get_tracks(sdp, state.filter_codecs)

    old_inbound_tracks = Map.values(state.inbound_tracks)

    if new_tracks?(inbound_tracks, state),
      do: inbound_tracks,
      else: old_inbound_tracks
  end

  defp new_tracks?(inbound_tracks, state) do
    known_ssrcs = Enum.map(state.inbound_tracks, fn {_id, track} -> track.ssrc end)
    Enum.any?(inbound_tracks, &(&1.ssrc not in known_ssrcs))
  end

  defp change_inbound_tracks(tracks, state) do
    track_id_to_track = Map.new(tracks, &{&1.id, &1})
    state = %{state | inbound_tracks: track_id_to_track}

    ssrc_to_track_id = Map.new(tracks, fn track -> {track.ssrc, track.id} end)
    state = %{state | ssrc_to_track_id: ssrc_to_track_id}

    actions = [notify: {:new_tracks, tracks}]
    {actions, state, tracks}
  end

  # As the mid of outbound_track can change between SDP offers and different browser can have
  # different payload_type for the same codec, so after receiving each sdp offer we update each outbound_track rtp_mapping and mid
  # based on data we receive in sdp offer
  defp update_outbound_tracks_by_type(medias, tracks, type) do
    medias = Enum.filter(medias, &(&1.media_type === type))
    tracks = Enum.filter(tracks, &(&1.type === type))

    Enum.zip(medias, tracks)
    |> Map.new(fn {media, track} ->
      {track.id, SDP.update_mapping_and_mid_for_track(track, media)}
    end)
  end

  defp update_outbound_tracks_mapping(sdp, outbound_tracks, state) do
    outbound_medias = SDP.get_recvonly_medias_mappings(sdp, state.filter_codecs)

    audio_tracks = update_outbound_tracks_by_type(outbound_medias, outbound_tracks, :audio)

    video_tracks = update_outbound_tracks_by_type(outbound_medias, outbound_tracks, :video)

    updated_outbound_tracks = Map.merge(audio_tracks, video_tracks)
    state = Map.update(state, :outbound_tracks, %{}, &Map.merge(&1, updated_outbound_tracks))
    {Map.values(updated_outbound_tracks), state}
  end

  defp get_track_id_to_mid(tracks),
    do: Map.new(tracks, fn track -> {track.id, track.mid} end)

  @impl true
  def handle_other({:signal, {:sdp_offer, sdp}}, _ctx, state) do
    {:ok, sdp} = sdp |> ExSDP.parse()

    inbound_tracks = get_inbound_tracks_from_sdp(sdp, state)

    outbound_tracks = Map.values(state.outbound_tracks) |> Enum.filter(&(&1.status != :none))

    {outbound_tracks, state} = update_outbound_tracks_mapping(sdp, outbound_tracks, state)

    {link_notify, state, inbound_tracks} =
      if new_tracks?(inbound_tracks, state),
        do: change_inbound_tracks(inbound_tracks, state),
        else: {[], state, Map.values(state.inbound_tracks)}

    answer =
      SDP.create_answer(
        inbound_tracks: inbound_tracks,
        outbound_tracks: outbound_tracks,
        ice_ufrag: state.ice.ufrag,
        ice_pwd: state.ice.pwd,
        fingerprint: state.dtls_fingerprint,
        sdp: sdp,
        video_codecs: state.video_codecs,
        audio_codecs: state.audio_codecs
      )

    {actions, state} =
      withl tracks_check: true <- state.inbound_tracks != %{} or outbound_tracks != %{},
            candidate_gathering_check: nil <- state.candidate_gathering_state do
        {[forward: [ice: :gather_candidates]], %{state | candidate_gathering_state: :in_progress}}
      else
        tracks_check: _ -> {[], state}
        candidate_gathering_check: _ -> {notify_candidates(state.candidates), state}
      end

    actions =
      [
        notify:
          {:signal,
           {:sdp_answer, to_string(answer),
            get_track_id_to_mid(inbound_tracks ++ outbound_tracks)}}
      ] ++
        set_remote_credentials(sdp) ++
        actions ++ link_notify

    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:signal, {:candidate, candidate}}, _ctx, state) do
    {{:ok, forward: {:ice, {:set_remote_candidate, "a=" <> candidate, 1}}}, state}
  end

  @impl true
  def handle_other({:add_tracks, tracks}, _ctx, state) do
    outbound_tracks = state.outbound_tracks

    change_track_readiness = fn track ->
      if Map.has_key?(outbound_tracks, track.id),
        do: track,
        else: %{track | status: :none, mid: nil}
    end

    tracks = tracks |> Enum.map(fn track -> change_track_readiness.(track) end)
    state = add_tracks(state, :outbound_tracks, tracks)
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  def handle_other({:remove_tracks, tracks_ids}, _ctx, state) do
    state = Map.update!(state, :outbound_tracks, &Map.drop(&1, tracks_ids))
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  def handle_other({:enable_track, track_id}, _ctx, state) do
    {{:ok, forward: {{:track_filter, track_id}, :enable_track}}, state}
  end

  @impl true
  def handle_other({:disable_track, track_id}, _ctx, state) do
    {{:ok, forward: {{:track_filter, track_id}, :disable_track}}, state}
  end

  defp maybe_restart_ice(state, set_waiting_restart? \\ false) do
    state =
      if set_waiting_restart?,
        do: %{state | ice: %{state.ice | waiting_restart?: true}},
        else: state

    if not state.ice.restarting? and state.ice.waiting_restart? do
      state = %{state | ice: %{state.ice | restarting?: true, waiting_restart?: false}}

      outbound_tracks = change_tracks_status(state, :none, :ready)

      state = %{state | outbound_tracks: outbound_tracks}

      {[forward: {:ice, :restart_stream}], state}
    else
      {[], state}
    end
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

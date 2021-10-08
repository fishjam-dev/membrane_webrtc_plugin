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
  alias Membrane.WebRTC.{SDP, Track, TrackFilter}

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
                spec: ({RTPMapping.t(), FMTP.t() | nil} -> boolean()),
                default: &SDP.filter_mappings(&1),
                description: "Defines function which will filter SDP m-line by codecs"
              ],
              log_metadata: [
                spec: :list,
                spec: Keyword.t(),
                default: [],
                description: "Logger metadata used for endpoint bin and all its descendants"
              ],
              endpoint_id: [
                spec: String.t(),
                description: "Endpoint id. It is used for creating Track id."
              ]

  def_input_pad :input,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      encoding: [
        spec: :OPUS | :H264 | :VP8,
        description: "Track encoding"
      ],
      track_enabled: [
        spec: boolean(),
        default: true,
        description: "Enable or disable track"
      ],
      use_payloader?: [
        spec: boolean(),
        default: true,
        description: "Defines if incoming stream should be payloaded based on given encoding"
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
      ],
      use_depayloader?: [
        spec: boolean(),
        default: true,
        description: "Use depayloader for outgoing stream"
      ],
      use_jitter_buffer?: [
        spec: boolean(),
        default: true,
        description: """
        Use jitter buffer before producing outgoing stream.

        Usually should go together with depayloader.
        """
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
        endpoint_id: opts.endpoint_id,
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

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, ctx, state) do
    # TODO: check this one
    %{track_enabled: track_enabled, encoding: encoding, use_payloader?: use_payloader?} = ctx.options
    %Track{ssrc: ssrc, rtp_mapping: mapping} = Map.fetch!(state.outbound_tracks, track_id)

    options = [
      encoding: encoding,
      clock_rate: mapping.clock_rate,
      payload_type: mapping.payload_type
    ]

    encoding_specific_links =
      case encoding do
        :H264 ->
          if use_payloader? do
            &to(&1, {:h264_parser, ssrc}, %Membrane.H264.FFmpeg.Parser{alignment: :nal})
          else
            & &1
          end

        _other ->
          & &1
      end

    links = [
      link_bin_input(pad)
      |> then(encoding_specific_links)
      |> to({:track_filter, track_id}, %TrackFilter{enabled: track_enabled})
      |> via_in(Pad.ref(:input, ssrc), options: [use_payloader?: use_payloader?])
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

    %{track_enabled: track_enabled} = ctx.options

    output_pad_options =
      ctx.options
      |> Map.take([:extensions, :packet_filters, :use_depayloader?])
      |> Map.put(:encoding, encoding)
      |> Map.put(:clock_rate, rtp_mapping.clock_rate)
      |> Map.to_list()

    spec = %ParentSpec{
      links: [
        link(:rtp)
        |> via_out(Pad.ref(:output, ssrc), options: output_pad_options)
        |> to({:track_filter, track_id}, %TrackFilter{
          enabled: track_enabled
        })
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
      |> Enum.filter(&(&1.status != :pending))
      |> Enum.map(& &1.type)

    media_count = %{
      audio: Enum.count(tracks_types, &(&1 == :audio)),
      video: Enum.count(tracks_types, &(&1 == :video))
    }

    actions = [notify: {:signal, {:offer_data, media_count}}]

    {{:ok, actions}, state}
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
  def handle_notification({:connection_failed, _stream_id, _component_id}, _from, _ctx, state) do
    state = %{state | ice: %{state.ice | restarting?: false}}
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  def handle_notification({:connection_ready, _stream_id, _component_id}, _from, _ctx, state)
      when state.ice.restarting? do
    outbound_tracks = Map.values(state.outbound_tracks) |> Enum.filter(&(&1.status != :pending))

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
  def handle_notification({:connection_ready, _stream_id, _component_id}, _from, _ctx, state)
      when not state.ice.restarting? do
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  def handle_notification(_notification, _from, _ctx, state), do: {:ok, state}

  @impl true
  def handle_other({:signal, {:sdp_offer, sdp}}, _ctx, state) do
    {:ok, sdp} = sdp |> ExSDP.parse()

    {new_inbound_tracks, inbound_tracks, outbound_tracks} = get_tracks_from_sdp(sdp, state)

    state = %{
      state
      | outbound_tracks: Map.merge(state.outbound_tracks, Map.new(outbound_tracks, &{&1.id, &1}))
    }

    {link_notify, state} = add_inbound_tracks(new_inbound_tracks, state)

    answer =
      SDP.create_answer(
        inbound_tracks: inbound_tracks,
        outbound_tracks: outbound_tracks,
        ice_ufrag: state.ice.ufrag,
        ice_pwd: state.ice.pwd,
        fingerprint: state.dtls_fingerprint,
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

    mid_to_track_id = Map.new(inbound_tracks ++ outbound_tracks, &{&1.mid, &1.id})

    actions =
      link_notify ++
        [notify: {:signal, {:sdp_answer, to_string(answer), mid_to_track_id}}] ++
        set_remote_credentials(sdp) ++
        actions

    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:signal, {:candidate, candidate}}, _ctx, state) do
    {{:ok, forward: {:ice, {:set_remote_candidate, "a=" <> candidate, 1}}}, state}
  end

  @impl true
  def handle_other({:signal, :renegotiate_tracks}, _ctx, state) do
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  def handle_other({:add_tracks, tracks}, _ctx, state) do
    outbound_tracks = state.outbound_tracks

    tracks =
      Enum.map(tracks, fn track ->
        if Map.has_key?(outbound_tracks, track.id),
          do: track,
          else: %{track | status: :pending, mid: nil}
      end)

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

      outbound_tracks = change_tracks_status(state, :pending, :ready)

      state = %{state | outbound_tracks: outbound_tracks}

      {[forward: {:ice, :restart_stream}], state}
    else
      {[], state}
    end
  end

  defp change_tracks_status(state, prev_status, new_status) do
    state.outbound_tracks
    |> Map.values()
    |> Map.new(fn track ->
      {track.id, if(track.status === prev_status, do: %{track | status: new_status}, else: track)}
    end)
  end

  defp get_tracks_from_sdp(sdp, state) do
    old_inbound_tracks = Map.values(state.inbound_tracks)

    outbound_tracks = Map.values(state.outbound_tracks) |> Enum.filter(&(&1.status != :pending))

    SDP.get_tracks(
      sdp,
      state.filter_codecs,
      old_inbound_tracks,
      outbound_tracks,
      state.endpoint_id
    )
  end

  defp add_inbound_tracks(new_tracks, state) do
    track_id_to_track = Map.new(new_tracks, &{&1.id, &1})
    state = Map.update!(state, :inbound_tracks, &Map.merge(&1, track_id_to_track))

    ssrc_to_track_id = Map.new(new_tracks, fn track -> {track.ssrc, track.id} end)
    state = Map.update!(state, :ssrc_to_track_id, &Map.merge(&1, ssrc_to_track_id))

    actions = [notify: {:new_tracks, new_tracks}]
    {actions, state}
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

  defp hex_dump(digest_str) do
    digest_str
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &Base.encode16(<<&1>>))
  end
end

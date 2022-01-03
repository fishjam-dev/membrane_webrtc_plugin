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
  use OpenTelemetryDecorator

  alias ExSDP.Media
  alias ExSDP.Attribute.{FMTP, RTPMapping}
  alias Membrane.TURN
  alias Membrane.ICE
  alias Membrane.WebRTC.{Extension, SDP, Track, TrackFilter}
  require OpenTelemetry.Tracer, as: Tracer

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
  @type enable_track_message :: {:enable_track, Track.id()}

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
              port_range: [
                spec: Range.t(),
                default: 0..0,
                description: "Port range to be used by `Membrane.ICE.Bin`"
              ],
              turn_servers: [
                type: :list,
                spec: [ExLibnice.relay_info()],
                default: [],
                description: "List of turn servers"
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
              rtcp_receiver_report_interval: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description:
                  "Receiver reports's generation interval, set to nil to avoid reports generation"
              ],
              rtcp_sender_report_interval: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description:
                  "Sender reports's generation interval, set to nil to avoid reports generation"
              ],
              filter_codecs: [
                spec: ({RTPMapping.t(), FMTP.t() | nil} -> boolean()),
                default: &SDP.filter_mappings(&1),
                description: "Defines function which will filter SDP m-line by codecs"
              ],
              extensions: [
                spec: [Extension.t()],
                default: [],
                description: "List of WebRTC extensions that should be enabled"
              ],
              log_metadata: [
                spec: :list,
                spec: Keyword.t(),
                default: [],
                description: "Logger metadata used for endpoint bin and all its descendants"
              ],
              integrated_turn_options: [
                spec: [TURN.Endpoint.integrated_turn_options_t()],
                default: [use_integrated_turn: false],
                description: "Integrated TURN Options"
              ],
              trace_metadata: [
                spec: :list,
                default: [],
                description: "A list of tuples to merge into Otel spans"
              ],
              trace_context: [
                spec: :list | any(),
                default: [],
                description: "Trace context for otel propagation"
              ]

  def_input_pad :input,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      track_enabled: [
        spec: boolean(),
        default: true,
        description: "Enable or disable track"
      ],
      use_payloader?: [
        spec: boolean(),
        default: true,
        description: """
        Defines if incoming stream should be payloaded based on given encoding.
        Otherwise the stream is assumed  be in RTP format.
        """
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
      extensions: [
        spec: [Membrane.RTP.SessionBin.extension_t()],
        default: [],
        description:
          "List of general extensions that will be applied to the SessionBin's output pad"
      ],
      use_depayloader?: [
        spec: boolean(),
        default: true,
        description: """
        Defines if the outgoing stream should get depayloaded.

        This option should be used as a convenience, it is not necessary as the new track notification
        returns a depayloading filter's definition that can be attached to the output pad
        to work the same way as with the option set to true.
        """
      ]
    ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    @type t :: %__MODULE__{
            id: String.t(),
            trace_metadata: Keyword.t(),
            log_metadata: Keyword.t(),
            inbound_tracks: %{Track.id() => Track.t()},
            outbound_tracks: %{Track.id() => Track.t()},
            rtcp_sender_report_interval: Membrane.Time.t() | nil,
            candidates: [any()],
            candidate_gathering_state: nil | :in_progress | :done,
            dtls_fingerprint: nil | {:sha256, binary()},
            ssrc_to_track_id: %{RTP.ssrc_t() => Track.id()},
            filter_codecs: ({RTPMapping.t(), FMTP.t() | nil} -> boolean()),
            extensions: [Extension.t()],
            integrated_turn_servers: [any()],
            ice: %{
              restarting?: boolean(),
              waiting_restart?: boolean(),
              pwd: nil | String.t(),
              ufrag: nil | String.t(),
              first?: boolean(),
              ice_lite?: boolean()
            }
          }

    defstruct id: "endpointBin",
              trace_metadata: [],
              log_metadata: [],
              inbound_tracks: %{},
              outbound_tracks: %{},
              rtcp_sender_report_interval: nil,
              candidates: [],
              candidate_gathering_state: nil,
              dtls_fingerprint: nil,
              ssrc_to_track_id: %{},
              filter_codecs: &SDP.filter_mappings(&1),
              extensions: [],
              integrated_turn_servers: [],
              ice: %{
                restarting?: false,
                waiting_restart?: false,
                pwd: nil,
                ufrag: nil,
                first?: true,
                ice_lite?: false
              }
  end

  @impl true
  def handle_init(opts) do
    trace_metadata =
      Keyword.merge(opts.trace_metadata, [
        {:"library.language", :erlang},
        {:"library.name", :membrane_webrtc_plugin},
        {:"library.version", "semver:#{Application.spec(:membrane_webrtc_plugin, :vsn)}"}
      ])

    create_or_join_otel_context(opts, trace_metadata)

    ice_impl =
      if opts.integrated_turn_options[:use_integrated_turn] do
        %TURN.Endpoint{
          integrated_turn_options: opts.integrated_turn_options,
          handshake_module: Membrane.DTLS.Handshake,
          handshake_opts: opts.handshake_opts
        }
      else
        %ICE.Bin{
          stun_servers: opts.stun_servers,
          turn_servers: opts.turn_servers,
          port_range: opts.port_range,
          controlling_mode: true,
          handshake_module: Membrane.DTLS.Handshake,
          handshake_opts: opts.handshake_opts
        }
      end

    ice_lite? = if opts.integrated_turn_options[:use_integrated_turn], do: true, else: false

    children = %{
      ice: ice_impl,
      rtp: %Membrane.RTP.SessionBin{
        secure?: true,
        rtcp_receiver_report_interval: opts.rtcp_receiver_report_interval,
        rtcp_sender_report_interval: opts.rtcp_sender_report_interval
      },
      ice_funnel: Membrane.Funnel
    }

    rtp_input_ref = make_ref()

    links = [
      # always link :rtcp_receiver_output to handle FIR RTCP packets
      link(:rtp)
      |> via_out(Pad.ref(:rtcp_receiver_output, rtp_input_ref))
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
      %State{
        id: Keyword.get(trace_metadata, :name, "endpointBin"),
        trace_metadata: trace_metadata,
        log_metadata: opts.log_metadata,
        inbound_tracks: %{},
        outbound_tracks: %{},
        rtcp_sender_report_interval: opts.rtcp_sender_report_interval,
        candidates: [],
        candidate_gathering_state: nil,
        dtls_fingerprint: nil,
        ssrc_to_track_id: %{},
        filter_codecs: opts.filter_codecs,
        extensions: opts.extensions,
        integrated_turn_servers: [],
        ice: %{
          restarting?: false,
          waiting_restart?: false,
          pwd: nil,
          ufrag: nil,
          first?: true,
          ice_lite?: ice_lite?
        }
      }
      |> add_tracks(:inbound_tracks, opts.inbound_tracks)
      |> add_tracks(:outbound_tracks, opts.outbound_tracks)

    {{:ok, spec: spec, log_metadata: opts.log_metadata}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.pad_added.input",
              include: [
                [:mapping, :clock_rate],
                [:mapping, :payload_type],
                :encoding,
                :ssrc,
                :track_enabled,
                :track_id,
                [:state, :id]
              ]
            )
  def handle_pad_added(Pad.ref(:input, track_id) = pad, ctx, state) do
    # TODO: check this one
    %{track_enabled: track_enabled, use_payloader?: use_payloader?} = ctx.options

    %Track{ssrc: ssrc, encoding: encoding, rtp_mapping: mapping, extmaps: extmaps} =
      Map.fetch!(state.outbound_tracks, track_id)

    rtp_extension_mapping = Map.new(extmaps, &Extension.as_rtp_mapping(state.extensions, &1))

    options = [
      encoding: encoding,
      clock_rate: mapping.clock_rate,
      payload_type: mapping.payload_type,
      rtp_extension_mapping: rtp_extension_mapping
    ]

    encoding_specific_links =
      case encoding do
        :H264 when use_payloader? ->
          &to(&1, {:h264_parser, ssrc}, %Membrane.H264.FFmpeg.Parser{alignment: :nal})

        _other ->
          & &1
      end

    payloader =
      if use_payloader? do
        {:ok, payloader} = Membrane.RTP.PayloadFormatResolver.payloader(encoding)

        payloader
      else
        nil
      end

    # link sender reports's pad only if we are going to generate the reports
    links =
      if state.rtcp_sender_report_interval do
        [
          link(:rtp)
          |> via_out(Pad.ref(:rtcp_sender_output, ssrc))
          |> to(:ice_funnel)
        ]
      else
        []
      end ++
        [
          link_bin_input(pad)
          |> then(encoding_specific_links)
          |> to({:track_filter, track_id}, %TrackFilter{enabled: track_enabled})
          |> via_in(Pad.ref(:input, ssrc), options: [payloader: payloader])
          |> to(:rtp)
          |> via_out(Pad.ref(:rtp_output, ssrc), options: options)
          |> to(:ice_funnel)
        ]

    {{:ok, spec: %ParentSpec{links: links}}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.pad_added.output",
              include: [
                [:rtp_mapping, :clock_rate],
                [:rtp_mapping, :payload_type],
                :ssrc,
                :track_enabled,
                :track_id,
                [:state, :id]
              ]
            )
  def handle_pad_added(Pad.ref(:output, track_id) = pad, ctx, state) do
    %Track{ssrc: ssrc, encoding: encoding, rtp_mapping: rtp_mapping, extmaps: extmaps} =
      track = Map.fetch!(state.inbound_tracks, track_id)

    %{track_enabled: track_enabled, use_depayloader?: use_depayloader?} = ctx.options

    depayloader =
      if use_depayloader? do
        {:ok, depayloader} = Membrane.RTP.PayloadFormatResolver.depayloader(encoding)

        depayloader
      else
        nil
      end

    rtp_extensions = Enum.map(extmaps, &Extension.as_rtp_extension(state.extensions, &1))

    output_pad_options = [
      extensions: ctx.options.extensions,
      rtp_extensions: rtp_extensions,
      clock_rate: rtp_mapping.clock_rate,
      depayloader: depayloader
    ]

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
  @decorate trace("endpoint_bin.notification.new_rtp_stream",
              include: [:track_id, :ssrc, [:state, :id]]
            )
  def handle_notification({:new_rtp_stream, ssrc, _pt, _extensions}, _from, _ctx, state) do
    track_id = Map.fetch!(state.ssrc_to_track_id, ssrc)
    track = Map.fetch!(state.inbound_tracks, track_id)
    track = %Track{track | ssrc: ssrc}
    state = put_in(state, [:inbound_tracks, track.id], track)
    depayloading_filter = depayloading_filter_for(track)

    {{:ok, notify: {:new_track, track.id, track.encoding, depayloading_filter}}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.handle_init_data",
              include: [[:state, :id]]
            )
  def handle_notification({:handshake_init_data, _component_id, fingerprint}, _from, _ctx, state) do
    {:ok, %{state | dtls_fingerprint: {:sha256, hex_dump(fingerprint)}}}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.local_credentials",
              include: [[:state, :ice, :first?], [:state, :id]]
            )
  def handle_notification({:local_credentials, credentials}, _from, _ctx, state) do
    [ice_ufrag, ice_pwd] = String.split(credentials, " ")

    {actions, state} =
      if state.ice.first? and state.outbound_tracks == %{} do
        {[], state}
      else
        state = Map.update!(state, :ice, &%{&1 | first?: false})
        get_offer_data(state)
      end

    state = %{state | ice: %{state.ice | ufrag: ice_ufrag, pwd: ice_pwd}}
    {{:ok, actions}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.new_candidate_full",
              include: [[:state, :id]]
            )
  def handle_notification({:new_candidate_full, cand}, _from, _ctx, state) do
    state = Map.update!(state, :candidates, &[cand | &1])
    {{:ok, notify_candidates([cand])}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.candidate_gathering_done",
              include: [[:state, :id]]
            )
  def handle_notification(:candidate_gathering_done, _from, _ctx, state) do
    {:ok, %{state | candidate_gathering_state: :done}}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.vad", include: [[:state, :id]])
  def handle_notification({:vad, _val} = msg, _from, _ctx, state) do
    {{:ok, notify: msg}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.connection_failed",
              include: [[:state, :id]]
            )
  def handle_notification({:connection_failed, _stream_id, _component_id}, _from, _ctx, state) do
    state = %{state | ice: %{state.ice | restarting?: false}}
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.connection_ready",
              include: [[:state, :ice, :restarting?], [:state, :id]]
            )
  def handle_notification({:connection_ready, _stream_id, _component_id}, _from, _ctx, state)
      when state.ice.restarting? do
    outbound_tracks = Map.values(state.outbound_tracks) |> Enum.filter(&(&1.status != :pending))

    new_outbound_tracks =
      outbound_tracks
      |> Enum.filter(&(&1.status === :ready))

    negotiations = [notify: {:negotiation_done, new_outbound_tracks}]

    state = %{state | outbound_tracks: change_tracks_status(state, :ready, :linked)}

    state = %{state | ice: %{state.ice | restarting?: false}}

    {restart_action, state} = maybe_restart_ice(state)

    actions = negotiations ++ restart_action

    {{:ok, actions}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.connection_ready",
              include: [[:state, :ice, :restarting?], [:state, :id]]
            )
  def handle_notification({:connection_ready, _stream_id, _component_id}, _from, _ctx, state)
      when not state.ice.restarting? do
    {action, state} = maybe_restart_ice(state, true)
    {{:ok, action}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.integrated_turn_servers",
              include: [[:state, :id]]
            )
  def handle_notification({:integrated_turn_servers, turns}, _from, _ctx, state) do
    state = Map.put(state, :integrated_turn_servers, turns)
    {:ok, state}
  end

  @impl true
  @decorate trace("endpoint_bin.notification.ignored_notification",
              include: [[:state, :id]]
            )
  def handle_notification(_notification, _from, _ctx, state), do: {:ok, state}

  @impl true
  @decorate trace("endpoint_bin.other.sdp_offer", include: [[:state, :id]])
  def handle_other({:signal, {:sdp_offer, sdp, mid_to_track_id}}, _ctx, state) do
    {:ok, sdp} = sdp |> ExSDP.parse()

    {new_inbound_tracks, removed_inbound_tracks, inbound_tracks, outbound_tracks} =
      get_tracks_from_sdp(sdp, mid_to_track_id, state)

    state = %{
      state
      | outbound_tracks: Map.merge(state.outbound_tracks, Map.new(outbound_tracks, &{&1.id, &1})),
        inbound_tracks: Map.merge(state.inbound_tracks, Map.new(inbound_tracks, &{&1.id, &1}))
    }

    {link_notify, state} = add_inbound_tracks(new_inbound_tracks, state)

    answer =
      SDP.create_answer(
        inbound_tracks: inbound_tracks,
        outbound_tracks: outbound_tracks,
        ice_ufrag: state.ice.ufrag,
        ice_pwd: state.ice.pwd,
        fingerprint: state.dtls_fingerprint,
        extensions: state.extensions,
        ice_lite: state.ice.ice_lite?
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
      if Enum.empty?(removed_inbound_tracks),
        do: actions,
        else: actions ++ [notify: {:removed_tracks, removed_inbound_tracks}]

    actions =
      link_notify ++
        [notify: {:signal, {:sdp_answer, to_string(answer), mid_to_track_id}}] ++
        set_remote_credentials(sdp) ++
        actions

    {{:ok, actions}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.other.candidate", include: [[:state, :id]])
  def handle_other({:signal, {:candidate, candidate}}, _ctx, state) do
    {{:ok, forward: {:ice, {:set_remote_candidate, "a=" <> candidate, 1}}}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.other.renegotiate_tracks", include: [[:state, :id]])
  def handle_other({:signal, :renegotiate_tracks}, _ctx, state) do
    {action, state} =
      cond do
        state.ice.first? and state.ice.pwd != nil ->
          state = Map.update!(state, :ice, &%{&1 | first?: false})
          get_offer_data(state)

        state.ice.first? ->
          state = Map.update!(state, :ice, &%{&1 | first?: false})
          {[], state}

        state.ice.pwd == nil ->
          {[], state}

        true ->
          maybe_restart_ice(state, true)
      end

    {{:ok, action}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.other.add_tracks", include: [[:state, :id]])
  def handle_other({:add_tracks, tracks}, _ctx, state) do
    outbound_tracks = state.outbound_tracks

    tracks =
      Enum.map(tracks, fn track ->
        if Map.has_key?(outbound_tracks, track.id),
          do: track,
          else: %{track | status: :pending, mid: nil}
      end)

    state = add_tracks(state, :outbound_tracks, tracks)

    {action, state} =
      cond do
        state.ice.first? and state.ice.pwd != nil ->
          state = Map.update!(state, :ice, &%{&1 | first?: false})
          outbound_tracks = change_tracks_status(state, :pending, :ready)
          state = %{state | outbound_tracks: outbound_tracks}
          get_offer_data(state)

        state.ice.first? and state.ice.pwd == nil ->
          outbound_tracks = change_tracks_status(state, :pending, :ready)
          state = %{state | outbound_tracks: outbound_tracks}
          {[], update_in(state, [:ice, :first?], fn _old_value -> false end)}

        true ->
          maybe_restart_ice(state, true)
      end

    {{:ok, action}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.other.remove_tracks", include: [[:state, :id]])
  def handle_other({:remove_tracks, tracks_to_remove}, _ctx, state) do
    outbound_tracks = state.outbound_tracks

    new_outbound_tracks =
      Enum.map(tracks_to_remove, &Map.get(outbound_tracks, &1.id))
      |> Map.new(fn track -> {track.id, %{track | status: :disabled}} end)

    {actions, state} =
      state
      |> Map.update!(:outbound_tracks, &Map.merge(&1, new_outbound_tracks))
      |> maybe_restart_ice(true)

    {{:ok, actions}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.other.enable_track", include: [[:state, :id]])
  def handle_other({:enable_track, track_id}, _ctx, state) do
    {{:ok, forward: {{:track_filter, track_id}, :enable_track}}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.other.disable_track", include: [[:state, :id]])
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

  defp get_offer_data(state) do
    tracks_types =
      Map.values(state.outbound_tracks)
      |> Enum.filter(&(&1.status != :pending))
      |> Enum.map(& &1.type)

    media_count = %{
      audio: Enum.count(tracks_types, &(&1 == :audio)),
      video: Enum.count(tracks_types, &(&1 == :video))
    }

    actions = [notify: {:signal, {:offer_data, media_count, state.integrated_turn_servers}}]
    state = Map.update!(state, :ice, &%{&1 | restarting?: true})

    {actions, state}
  end

  defp change_tracks_status(state, prev_status, new_status) do
    state.outbound_tracks
    |> Map.values()
    |> Map.new(fn track ->
      {track.id, if(track.status === prev_status, do: %{track | status: new_status}, else: track)}
    end)
  end

  defp get_tracks_from_sdp(sdp, mid_to_track_id, state) do
    old_inbound_tracks = Map.values(state.inbound_tracks)

    outbound_tracks = Map.values(state.outbound_tracks) |> Enum.filter(&(&1.status != :pending))

    SDP.get_tracks(
      sdp,
      state.filter_codecs,
      state.extensions,
      old_inbound_tracks,
      outbound_tracks,
      mid_to_track_id
    )
  end

  defp add_inbound_tracks(new_tracks, state) do
    track_id_to_track = Map.new(new_tracks, &{&1.id, &1})
    state = Map.update!(state, :inbound_tracks, &Map.merge(&1, track_id_to_track))

    ssrc_to_track_id = Map.new(new_tracks, fn track -> {track.ssrc, track.id} end)
    state = Map.update!(state, :ssrc_to_track_id, &Map.merge(&1, ssrc_to_track_id))

    actions = if Enum.empty?(new_tracks), do: [], else: [notify: {:new_tracks, new_tracks}]
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

  defp depayloading_filter_for(track) do
    case Membrane.RTP.PayloadFormatResolver.depayloader(track.encoding) do
      {:ok, depayloader} ->
        %Membrane.RTP.DepayloaderBin{
          depayloader: depayloader,
          clock_rate: track.rtp_mapping.clock_rate
        }

      :error ->
        nil
    end
  end

  defp create_or_join_otel_context(opts, trace_metadata) do
    case opts.trace_context do
      [] ->
        root_span = Tracer.start_span("endpoint_bin")
        parent_ctx = Tracer.set_current_span(root_span)
        otel_ctx = OpenTelemetry.Ctx.attach(parent_ctx)
        OpenTelemetry.Span.set_attributes(root_span, trace_metadata)
        OpenTelemetry.Span.end_span(root_span)
        OpenTelemetry.Ctx.attach(otel_ctx)
        [otel_ctx]

      [ctx | _] ->
        OpenTelemetry.Ctx.attach(ctx)
        [ctx]

      ctx ->
        OpenTelemetry.Ctx.attach(ctx)
        root_span = Tracer.start_span("endpoint_bin")
        parent_ctx = Tracer.set_current_span(root_span)
        otel_ctx = OpenTelemetry.Ctx.attach(parent_ctx)
        OpenTelemetry.Span.set_attributes(root_span, trace_metadata)
        OpenTelemetry.Span.end_span(root_span)
        OpenTelemetry.Ctx.attach(otel_ctx)
        otel_ctx
    end
  end
end

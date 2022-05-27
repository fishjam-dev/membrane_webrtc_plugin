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
  alias Membrane.ICE
  alias Membrane.WebRTC.{Extension, SDP, Track}
  require OpenTelemetry.Tracer, as: Tracer

  # we always want to use ICE lite at the moment
  @ice_lite true

  @type signal_message ::
          {:signal, {:sdp_offer | :sdp_answer, String.t()} | {:candidate, String.t()}}

  @type track_message :: alter_tracks_message()

  @typedoc """
  Message that adds or removes tracks.
  """
  @type alter_tracks_message :: {:add_tracks, [Track.t()]} | {:remove_tracks, [Track.id()]}

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
              handshake_opts: [
                type: :list,
                spec: Keyword.t(),
                default: [],
                description: """
                Keyword list with options for handshake module. For more information please
                refer to `t:ExDTLS.opts_t/0`
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
                spec: [ICE.Endpoint.integrated_turn_options_t()],
                default: [],
                description: "Integrated TURN Options"
              ],
              simulcast?: [
                spec: boolean(),
                default: true,
                description: """
                Whether to accept simulcast tracks or not.
                If set to `false`, simulcast tracks will be disabled i.e.
                sender will not send them.
                """
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
              ],
              telemetry_label: [
                spec: Membrane.TelemetryMetrics.label(),
                default: [],
                description: "Label passed to Membrane.TelemetryMetrics functions"
              ]

  def_input_pad :input,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
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
      ],
      rtcp_fir_interval: [
        spec: Membrane.Time.t() | nil,
        default: Membrane.Time.second(),
        description: """
        Defines how often FIR should be sent.

        For more information refer to RFC 5104 section 4.3.1.
        """
      ]
    ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    @typedoc """
    * `simulcast_track_ids` - list of simulcast track ids.
    * `ssrc_to_track_id` - maps ssrc to track id.
    If track is a simulcast track it might not be in this list until
    we receive its first RTP packets. This is beacuse simulcast tracks
    don't announce their SSRCs in SDP. Instead, we have to wait for
    their first RTP packets. There might be many SSRC pointing to the same track.
    """
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
            simulcast_track_ids: [Track.id()],
            ssrc_to_track_id: %{RTP.ssrc_t() => Track.id()},
            filter_codecs: ({RTPMapping.t(), FMTP.t() | nil} -> boolean()),
            extensions: [Extension.t()],
            integrated_turn_servers: [any()],
            component_path: String.t(),
            simulcast?: boolean(),
            telemetry_label: Membrane.TelemetryMetrics.label(),
            ice: %{
              restarting?: boolean(),
              waiting_restart?: boolean(),
              pwd: nil | String.t(),
              ufrag: nil | String.t(),
              first?: boolean()
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
              simulcast_track_ids: [],
              ssrc_to_track_id: %{},
              filter_codecs: &SDP.filter_mappings(&1),
              extensions: [],
              integrated_turn_servers: [],
              component_path: "",
              simulcast?: true,
              telemetry_label: [],
              ice: %{
                restarting?: false,
                waiting_restart?: false,
                pwd: nil,
                ufrag: nil,
                first?: true
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

    children = %{
      ice: %ICE.Endpoint{
        integrated_turn_options: opts.integrated_turn_options,
        handshake_opts: opts.handshake_opts,
        telemetry_label: opts.telemetry_label
      },
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
      links: links,
      log_metadata: opts.log_metadata
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
        integrated_turn_servers: ICE.TURNManager.get_launched_turn_servers(),
        extensions: Enum.map(opts.extensions, &if(is_struct(&1), do: &1, else: &1.new())),
        component_path: Membrane.ComponentPath.get_formatted(),
        simulcast?: opts.simulcast?,
        telemetry_label: opts.telemetry_label,
        ice: %{
          restarting?: false,
          waiting_restart?: false,
          pwd: nil,
          ufrag: nil,
          first?: true
        }
      }
      |> add_tracks(:inbound_tracks, opts.inbound_tracks)
      |> add_tracks(:outbound_tracks, opts.outbound_tracks)

    {{:ok, spec: spec}, state}
  end

  @impl true
  @decorate trace("endpoint_bin.pad_added.input",
              include: [
                [:mapping, :clock_rate],
                [:mapping, :payload_type],
                :encoding,
                :ssrc,
                :track_id,
                [:state, :id]
              ]
            )
  def handle_pad_added(Pad.ref(:input, track_id) = pad, ctx, state) do
    # TODO: check this one
    %{use_payloader?: use_payloader?} = ctx.options

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
                :track_id,
                [:state, :id]
              ]
            )
  def handle_pad_added(Pad.ref(:output, {track_id, rid}) = pad, ctx, state) do
    %Track{ssrc: ssrc, encoding: encoding, rtp_mapping: rtp_mapping, extmaps: extmaps} =
      track = Map.fetch!(state.inbound_tracks, track_id)

    # if `rid` is set, it is a request for specific encoding of simulcast track
    # choose ssrc which corresponds to given `rid`
    ssrc = if rid, do: Map.fetch!(track.rid_to_ssrc, rid), else: ssrc

    %{
      use_depayloader?: use_depayloader?,
      rtcp_fir_interval: rtcp_fir_interval
    } = ctx.options

    depayloader =
      if use_depayloader? do
        {:ok, depayloader} = Membrane.RTP.PayloadFormatResolver.depayloader(encoding)

        depayloader
      else
        nil
      end

    rtp_extensions =
      extmaps
      |> Enum.map(&Extension.as_rtp_extension(state.extensions, &1))
      |> Enum.reject(fn {_name, rtp_module} -> rtp_module == :no_rtp_module end)

    telemetry_label = state.telemetry_label ++ [track_id: "#{track_id}:#{rid}"]

    output_pad_options = [
      extensions: ctx.options.extensions,
      rtp_extensions: rtp_extensions,
      clock_rate: rtp_mapping.clock_rate,
      depayloader: depayloader,
      telemetry_label: telemetry_label,
      encoding: encoding,
      rtcp_fir_interval: rtcp_fir_interval
    ]

    spec = %ParentSpec{
      links: [
        link(:rtp)
        |> via_out(Pad.ref(:output, ssrc), options: output_pad_options)
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
  def handle_notification(
        {:new_rtp_stream, ssrc, _pt, rtp_header_extensions},
        _from,
        _ctx,
        state
      ) do
    track_id = Map.get(state.ssrc_to_track_id, ssrc)

    track =
      if track_id do
        Map.fetch!(state.inbound_tracks, track_id)
      else
        # search in simulcast tracks
        simulcast_tracks =
          state.inbound_tracks
          |> Enum.filter(fn {inbound_track_id, _inbound_track} ->
            inbound_track_id in state.simulcast_track_ids
          end)
          |> Enum.map(fn {_simulcast_track_id, simulcast_track} -> simulcast_track end)

        Enum.find(simulcast_tracks, fn simulcast_track ->
          resolved_rtp_extensions =
            SDP.resolve_rtp_header_extensions(
              simulcast_track,
              rtp_header_extensions,
              state.extensions
            )

          if resolved_rtp_extensions.mid == <<>>,
            do: raise("No MID extension for RTP stream #{inspect(ssrc)}")

          simulcast_track.mid == resolved_rtp_extensions.mid
        end)
      end

    resolved_rtp_extensions =
      SDP.resolve_rtp_header_extensions(track, rtp_header_extensions, state.extensions)

    # this might be nil when track is not a simulcast one
    rid = Map.get(resolved_rtp_extensions, :rid)

    state =
      if track.ssrc == ssrc do
        # casual track
        state
      else
        # simulcast track
        track = %Track{
          track
          | ssrc: [ssrc | track.ssrc],
            rid_to_ssrc: Map.put(track.rid_to_ssrc, rid, ssrc)
        }

        put_in(state, [:inbound_tracks, track.id], track)
      end

    state = put_in(state, [:ssrc_to_track_id, ssrc], track.id)
    depayloading_filter = depayloading_filter_for(track)

    notification = {:new_track, track.id, rid, track.encoding, depayloading_filter}

    {{:ok, [{:notify, notification}]}, state}
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
  def handle_notification({:connection_ready, _stream_id, _component_id}, _from, _ctx, state),
    do: {:ok, state}

  @impl true
  @decorate trace("endpoint_bin.notification.integrated_turn_servers",
              include: [[:state, :id]]
            )
  def handle_notification({:udp_integrated_turn, turn}, _from, _ctx, state) do
    state = %{state | integrated_turn_servers: [turn] ++ state.integrated_turn_servers}
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

    state =
      removed_inbound_tracks
      |> Enum.map(fn track -> track.id end)
      |> then(fn removed_inbound_track_ids ->
        update_in(state, [:simulcast_track_ids], &(&1 -- removed_inbound_track_ids))
      end)

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
        ice_lite?: @ice_lite
      )

    {actions, state} =
      withl tracks_check: true <- state.inbound_tracks != %{} or state.outbound_tracks != %{},
            candidate_gathering_check: nil <- state.candidate_gathering_state do
        {[forward: [ice: :gather_candidates]], %{state | candidate_gathering_state: :in_progress}}
      else
        tracks_check: _ -> {[], state}
        candidate_gathering_check: _ -> {notify_candidates(state.candidates), state}
      end

    inbound_tracks = SDP.filter_simulcast_tracks(inbound_tracks)
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
  @decorate trace("endpoint_bin.other.add_tracks",
              include: [[:state, :component_path], [:state, :id]]
            )
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
      mid_to_track_id,
      state.simulcast?
    )
  end

  defp add_inbound_tracks(new_tracks, state) do
    new_track_id_to_track = Map.new(new_tracks, &{&1.id, &1})
    state = Map.update!(state, :inbound_tracks, &Map.merge(&1, new_track_id_to_track))

    {new_simulcast_tracks, new_casual_tracks} = Enum.split_with(new_tracks, &(&1.ssrc == []))

    new_ssrc_to_track_id =
      Enum.into(new_casual_tracks, %{}, fn track -> {track.ssrc, track.id} end)

    new_simulcast_track_ids = Enum.map(new_simulcast_tracks, fn track -> track.id end)

    state =
      state
      |> Map.update!(:ssrc_to_track_id, &Map.merge(&1, new_ssrc_to_track_id))
      |> Map.update!(:simulcast_track_ids, &(&1 ++ new_simulcast_track_ids))

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

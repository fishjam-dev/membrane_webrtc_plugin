defmodule Membrane.WebRTC.EndpointBin.TracksState do
  @moduledoc false
  # Part of the EndpointBin's state responsible for handling tracks

  alias Membrane.RTP
  alias Membrane.WebRTC.{SDP, Track}

  @type stream_info() ::
          {:unicast, :media | :rtx, nil, Track.id()}
          | {:simulcast, :media | :rtx, Track.rid(), Track.id()}

  @type t() :: %{
          inbound: %{Track.id() => Track.t()},
          outbound: %{Track.id() => Track.t()},
          used_ssrcs: MapSet.t(RTP.ssrc_t()),
          ssrc_to_track_id: %{RTP.ssrc_t() => Track.id()},
          rtx_ssrc_to_track_id: %{RTP.ssrc_t() => Track.id()}
        }
  defstruct inbound: %{},
            outbound: %{},
            used_ssrcs: MapSet.new(),
            ssrc_to_track_id: %{},
            rtx_ssrc_to_track_id: %{}

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{inbound: inbound, outbound: outbound}) do
    map_size(inbound) == 0 and map_size(outbound) == 0
  end

  @spec add_inbound_tracks(t(), [Track.t()]) :: t()
  def add_inbound_tracks(state, []), do: state

  def add_inbound_tracks(state, tracks) do
    tracks
    |> Enum.reduce(state, fn track, state ->
      state = put_in(state.inbound[track.id], track)

      state =
        if Track.simulcast?(track) do
          state
        else
          state
          |> Map.put(:used_ssrcs, MapSet.put(state.used_ssrcs, track.ssrc))
          |> put_in([:ssrc_to_track_id, track.ssrc], track.id)
        end

      state =
        if Track.simulcast?(track) or is_nil(track.rtx_ssrc) do
          state
        else
          state
          |> Map.put(:used_ssrcs, MapSet.put(state.used_ssrcs, track.rtx_ssrc))
          |> put_in([:rtx_ssrc_to_track_id, track.rtx_ssrc], track.id)
        end

      state
    end)
  end

  @spec add_outbound_tracks(t(), [Track.t()]) :: t()
  def add_outbound_tracks(state, []), do: state

  def add_outbound_tracks(state, tracks) do
    {tracks, used_ssrcs} = generate_ssrcs(tracks, state.used_ssrcs)

    tracks_map =
      Map.new(tracks, fn track ->
        {track.id, %{track | status: :pending, mid: nil}}
      end)

    %__MODULE__{
      state
      | used_ssrcs: used_ssrcs,
        outbound:
          Map.merge(state.outbound, tracks_map, fn id, _t1, _t2 ->
            raise "Trying to add existing track #{id}"
          end)
    }
  end

  defp generate_ssrcs(tracks, restricted_ssrcs) do
    tracks
    |> Bunch.listify()
    |> Enum.map_reduce(restricted_ssrcs, fn track, restricted_ssrcs ->
      ssrc =
        fn -> :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() end
        |> Stream.repeatedly()
        |> Enum.find(&(&1 not in restricted_ssrcs))

      {%Track{track | ssrc: ssrc}, MapSet.put(restricted_ssrcs, ssrc)}
    end)
  end

  @spec change_outbound_status(t(), Track.status(), Track.status()) :: t()
  def change_outbound_status(state, prev_status, new_status) do
    outbound =
      state.outbound
      |> Map.new(fn
        {id, %Track{status: ^prev_status} = track} -> {id, %Track{track | status: new_status}}
        other -> other
      end)

    %__MODULE__{outbound: outbound}
  end

  @spec disable_tracks(t(), [Track.t()]) :: t()
  def disable_tracks(state, tracks_to_disable) do
    new_outbound_tracks =
      tracks_to_disable
      |> Enum.map(&Map.get(state.outbound, &1.id))
      |> Map.new(fn track -> {track.id, %{track | status: :disabled}} end)

    %__MODULE__{state | outbound: Map.merge(state.outbound, new_outbound_tracks)}
  end

  @spec identify_inbound_stream(
          t(),
          RTP.ssrc_t(),
          RTP.payload_type_t(),
          RTP.Header.Extension.t(),
          Membrane.WebRTC.Extension.t()
        ) ::
          stream_info()
  def identify_inbound_stream(%{ssrc_to_track_id: tracks}, ssrc, _pt, _raw_exts, _webrtc_exts)
      when is_map_key(tracks, ssrc) do
    {:unicast, :media, nil, tracks[ssrc]}
  end

  def identify_inbound_stream(%{rtx_ssrc_to_track_id: tracks}, ssrc, _pt, _raw_exts, _webrtc_exts)
      when is_map_key(tracks, ssrc) do
    {:unicast, :rtx, nil, tracks[ssrc]}
  end

  # It must be simulcast then, try using mid
  def identify_inbound_stream(state, ssrc, pt, packet_extensions, webrtc_extensions) do
    {%Track{} = track, resolved_extensions} =
      find_track_by_mid(
        state.inbound,
        webrtc_extensions,
        packet_extensions
      )

    if is_nil(track) do
      raise "Unknown track! pt: #{pt}, ssrc: #{ssrc}"
    end

    {type, rid} =
      if Map.get(track.selected_encoding.rtx, :payload_type) == pt do
        {:rtx, Map.get(resolved_extensions, :repaired_rid)}
      else
        {:media, Map.get(resolved_extensions, :rid)}
      end

    if is_nil(rid) do
      raise """
      No RID extension found for RTP stream #{inspect(ssrc)}!
      Only RID-based simulcast is supported. Ensure RID extension is enabled and supported by the WebRTC client
      """
    end

    {:simulcast, type, rid, track.id}
  end

  defp find_track_by_mid(tracks, webrtc_extensions, new_stream_extensions) do
    tracks
    |> Enum.find_value({nil, %{}}, fn track ->
      resolved_rtp_extensions =
        SDP.resolve_rtp_header_extensions(
          track,
          new_stream_extensions,
          webrtc_extensions
        )

      if Map.get(resolved_rtp_extensions, :mid, <<>>) == <<>> do
        raise """
        No MID extension for RTP stream!
        Such streams are not supported. It is possible that it comes from an outdated browser.
        The browser known to send such stream is Safari in version older than 15.4
        """
      end

      if track.mid == resolved_rtp_extensions.mid do
        {track, resolved_rtp_extensions}
      else
        nil
      end
    end)
  end

  @spec register_stream(t(), RTP.ssrc_t(), stream_info()) :: t()
  def register_stream(state, ssrc, info) do
    state
    |> Map.put(:used_ssrcs, MapSet.put(state.used_ssrcs, ssrc))
    |> do_register_stream(ssrc, info)
  end

  defp do_register_stream(state, ssrc, {:unicast, :media, nil, track_id}) do
    put_in(state, [:ssrc_to_track_id, ssrc], track_id)
  end

  defp do_register_stream(state, ssrc, {:unicast, :rtx, nil, track_id}) do
    state
    |> put_in([:inbound, track_id, :rtx_ssrc], ssrc)
    |> put_in([:rtx_ssrc_to_track_id, ssrc], track_id)
  end

  defp do_register_stream(state, ssrc, {:simulcast, :media, rid, track_id}) do
    state
    |> update_in([:inbound, track_id], fn track ->
      %Track{
        track
        | ssrc: [ssrc | track.ssrc],
          rid_to_ssrc: Map.put(track.rid_to_ssrc, rid, ssrc)
      }
    end)
    |> put_in([:ssrc_to_track_id, ssrc], track_id)
  end

  defp do_register_stream(state, ssrc, {:simulcast, :rtx, _rid, track_id}) do
    state
    |> update_in([:inbound, track_id], fn track ->
      %Track{track | rtx_ssrc: [ssrc | track.rtx_ssrc]}
    end)
    |> put_in([:rtx_ssrc_to_track_id, ssrc], track_id)
  end
end

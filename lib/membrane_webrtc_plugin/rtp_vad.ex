defmodule Membrane.RTPVAD do
  @moduledoc """
  Simple vad based on audio level sent in RTP header.

  If avg of audio level in packets in `time_window` exceeds `vad_threshold` it emits
  notification `{:vad, true}`.

  When avg falls below `vad_threshold` and doesn't exceed it in the next `vad_silence_timer`
  it emits notification `{:vad, false}`.
  """
  use Membrane.Filter

  def_input_pad :input,
    availability: :always,
    caps: :any,
    demand_unit: :buffers

  def_output_pad :output,
    availability: :always,
    caps: :any

  def_options time_window: [
                spec: pos_integer(),
                default: 2_000_000_000,
                description: "Time window (in `ns`) in which avg audio level is measured."
              ],
              min_packet_num: [
                spec: pos_integer(),
                default: 50,
                description: """
                Minimal number of packets to count avg audio level from.
                If e.g. there is only one packet in last `time_window` then to count avg audio level
                packets representing digital silence will be taken in number equal to
                `min_packet_num - 1`
                """
              ],
              vad_threshold: [
                spec: -127..0,
                default: -50,
                description: """
                Audio level in dBov representing vad threshold.
                Values above are considered to represent voice activity.
                Value -127 represents digital silence.
                """
              ],
              vad_silence_time: [
                spec: pos_integer(),
                default: 300,
                description: """
                Time to wait before emitting notification `{:vad, false}` after audio track is
                no longer considered to represent speech.
                If at this time audio track is considered to represent speech again the notification
                `{:vad, false}` will not be sent.
                """
              ]

  @impl true
  def handle_init(opts) do
    state = %{
      audio_levels: Qex.new(),
      vad: :silence,
      vad_silence_timestamp: 0,
      current_timestamp: 0,
      time_window: opts.time_window,
      min_packet_num: opts.min_packet_num,
      vad_threshold: opts.vad_threshold,
      vad_silence_time: opts.vad_silence_time
    }

    {:ok, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    <<_id::4, _len::4, _v::1, level::7, _rest::binary-size(2)>> =
      buffer.metadata.rtp.extension.data

    state = %{state | current_timestamp: buffer.metadata.timestamp}
    audio_levels = filter(state.audio_levels, buffer.metadata.timestamp, state.time_window)
    audio_levels = Qex.push(audio_levels, {-1 * level, buffer.metadata.timestamp})
    new_vad = get_current_vad(audio_levels, state)
    actions = [buffer: {:output, buffer}] ++ maybe_notify(new_vad, state)
    state = update_state(audio_levels, new_vad, state)
    {{:ok, actions}, state}
  end

  defp filter(audio_levels, current_timestamp, time_window) do
    Enum.drop_while(audio_levels, fn {_level, timestamp} ->
      current_timestamp - timestamp > time_window
    end)
    |> Enum.into(%Qex{})
  end

  defp get_current_vad(audio_levels, state) do
    audio_levels = fill(Enum.to_list(audio_levels), state.min_packet_num)
    if avg(audio_levels) >= state.vad_threshold, do: :speech, else: :silence
  end

  defp fill(audio_levels, num) when is_list(audio_levels) do
    # add audio levels representing digital silence if there are
    # not enough regular audio levels
    num = max(num - length(audio_levels), 0)
    audio_levels ++ List.duplicate({-127, 0}, num)
  end

  defp avg(list) when is_list(list) do
    Enum.reduce(list, 0, fn {level, _timestamp}, acc -> level + acc end) / length(list)
  end

  defp maybe_notify(new_vad, state) do
    if vad_silence?(new_vad, state) or vad_speech?(new_vad, state) do
      [notify: {:vad, new_vad}]
    else
      []
    end
  end

  defp update_state(audio_levels, new_vad, state) do
    cond do
      vad_maybe_silence?(new_vad, state) ->
        Map.merge(state, %{vad: :maybe_silence, vad_silence_timestamp: state.current_timestamp})

      vad_silence?(new_vad, state) or vad_speech?(new_vad, state) or
          (state.vad == :maybe_silence and new_vad == :speech) ->
        Map.merge(state, %{vad: new_vad})

      true ->
        state
    end
    |> Map.put(:audio_levels, audio_levels)
  end

  defp vad_silence?(new_vad, state),
    do: state.vad == :maybe_silence and new_vad == :silence and timer_expired?(state)

  defp vad_speech?(new_vad, state), do: state.vad == :silence and new_vad == :speech

  defp vad_maybe_silence?(new_vad, state), do: state.vad == :speech and new_vad == :silence

  defp timer_expired?(state),
    do: state.current_timestamp - state.vad_silence_timestamp > state.vad_silence_time
end

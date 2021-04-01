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
                Speech won't be detected until there are enough packets.
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
      vad_silence_time: opts.vad_silence_time,
      audio_levels_sum: 0,
      audio_levels_count: 0
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
    state = filter_old_audio_levels(state)
    state = add_new_audio_level(state, level)
    new_vad = get_new_vad(audio_levels, state)
    actions = [buffer: {:output, buffer}] ++ maybe_notify(new_vad, state)
    state = update_state(new_vad, state)
    {{:ok, actions}, state}
  end

  defp filter_old_audio_levels(state) do
    Enum.reduce_while(state.audio_levels, state, fn {level, timestamp}, state ->
      if state.current_timestamp - timestamp > state.time_window do
        {_level, audio_levels} = Qex.pop(state.audio_levels)
        state = %{state | audio_levels_sum: state.audio_levels_sum - level}
        state = %{state | audio_levels_count: state.audio_levels_count - 1}
        state = %{state | audio_levels: audio_levels}
        {:cont, state}
      else
        {:halt, state}
      end
    end)
  end

  defp add_new_audio_level(state, level) do
    audio_levels = Qex.push(state.audio_levels, {-1 * level, state.current_timestamp})
    state = %{state | audio_levels_sum: state.audio_levels_sum + level}
    state = %{state | audio_levels_count: state.audio_levels_count + 1}
  end

  defp get_new_vad(audio_levels, state) do
    if Enum.count(audio_levels >= state.min_packet_num) do
      if avg(audio_levels) >= state.vad_threshold, do: :speech, else: :silence
    else
      # if there aren't enough packets assume silence
      :silence
    end
  end

  defp avg(state), do: state.audio_levels_sum / state.audio_levels_count

  defp maybe_notify(new_vad, state) do
    if vad_silence?(new_vad, state) or vad_speech?(new_vad, state) do
      [notify: {:vad, new_vad}]
    else
      []
    end
  end

  defp update_state(new_vad, state) do
    cond do
      vad_maybe_silence?(new_vad, state) ->
        Map.merge(state, %{vad: :maybe_silence, vad_silence_timestamp: state.current_timestamp})

      vad_silence?(new_vad, state) or vad_speech?(new_vad, state) or
          (state.vad == :maybe_silence and new_vad == :speech) ->
        Map.merge(state, %{vad: new_vad})

      true ->
        state
    end
  end

  defp vad_silence?(new_vad, state),
    do: state.vad == :maybe_silence and new_vad == :silence and timer_expired?(state)

  defp vad_speech?(new_vad, state), do: state.vad == :silence and new_vad == :speech

  defp vad_maybe_silence?(new_vad, state), do: state.vad == :speech and new_vad == :silence

  defp timer_expired?(state),
    do: state.current_timestamp - state.vad_silence_timestamp > state.vad_silence_time
end

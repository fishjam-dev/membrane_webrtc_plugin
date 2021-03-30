defmodule Membrane.RTPVAD do
  @moduledoc """
  Simple vad based on audio level sent in RTP header.

  If avg of audio level in last 50 packets exceeds some threshold it emits
  notification `{:vad, true}`.

  When avg fall below threshold and doesn't exceeds it in the next 300ms it emits
  notification `{:vad, false}`.
  """
  use Membrane.Filter

  def_input_pad :input,
    availability: :always,
    caps: :any,
    demand_unit: :buffers

  def_output_pad :output,
    availability: :always,
    caps: :any

  @impl true
  def handle_init(_opts) do
    {:ok,
     %{
       audio_levels: Qex.new(),
       vad: false,
       vad_false_timer: get_time(),
       # ns
       time_window: 2_000_000_000
     }}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    <<_id::4, _len::4, _v::1, level::7, _rest::binary-size(2)>> =
      buffer.metadata.rtp.extension.data

    audio_levels = filter(state.audio_levels, buffer.metadata.timestamp, state.time_window)
    audio_levels = Qex.push(audio_levels, {level, buffer.metadata.timestamp})
    new_vad = avg(fill(Enum.to_list(audio_levels), 50)) < 50
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

  defp fill(audio_levels, num) when is_list(audio_levels) do
    # add audio levels representing digital silence if there are
    # not enough regular audio levels
    num = max(num - length(audio_levels), 0)
    audio_levels ++ List.duplicate({127, 0}, num)
  end

  defp avg(list) when is_list(list) do
    Enum.reduce(list, 0, fn {level, _timestamp}, acc -> level + acc end) / length(list)
  end

  defp maybe_notify(new_vad, state) do
    if vad_false?(new_vad, state) or vad_true?(new_vad, state) do
      [notify: {:vad, new_vad}]
    else
      []
    end
  end

  defp update_state(audio_levels, new_vad, state) do
    cond do
      vad_maybe_false?(new_vad, state) ->
        Map.merge(state, %{vad: :maybe_false, vad_false_timer: get_time()})

      vad_false?(new_vad, state) or vad_true?(new_vad, state) or
          (state.vad == :maybe_false and new_vad == true) ->
        Map.merge(state, %{vad: new_vad})

      true ->
        state
    end
    |> Map.put(:audio_levels, audio_levels)
  end

  defp vad_false?(new_vad, state),
    do: state.vad == :maybe_false and new_vad == false and timer_expired?(state)

  defp vad_true?(new_vad, state), do: state.vad == false and new_vad == true

  defp vad_maybe_false?(new_vad, state), do: state.vad == true and new_vad == false

  defp get_time(), do: System.monotonic_time(:millisecond)

  defp timer_expired?(state), do: get_time() - state.vad_false_timer > 300
end

defmodule Membrane.WebRTC.TrackFilter do
  @moduledoc """
  Allows for disabling and enabling track.

  Sending `:disable_track` causes all packets are ignored.
  Sending `:enable_track` causes all packets are conveyed to the filter output pad.
  By default track is enabled.
  """
  use Membrane.Filter

  def_options enabled: [
                type: :boolean,
                spec: boolean(),
                default: true,
                description: "Enable or disable track"
              ]

  def_input_pad :input,
    availability: :always,
    caps: :any,
    demand_unit: :buffers,
    demand_mode: :auto

  def_output_pad :output,
    availability: :always,
    caps: :any,
    demand_mode: :auto

  @impl true
  def handle_init(opts) do
    {:ok, %{enabled: opts.enabled}}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{}, _ctx, %{enabled: false} = state) do
    {{:ok, redemand: :output}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, %{enabled: true} = state) do
    {{:ok, buffer: {:output, buffer}}, state}
  end

  @impl true
  def handle_other(:enable_track, _ctx, state), do: {:ok, %{state | enabled: true}}

  @impl true
  def handle_other(:disable_track, _ctx, state), do: {:ok, %{state | enabled: false}}
end

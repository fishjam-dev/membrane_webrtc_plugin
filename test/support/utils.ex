defmodule Membrane.WebRTC.Test.Utils do
  @moduledoc false
  alias Membrane.WebRTC.Track

  @doc """
  Returns DTLS certificate fingerprint in binary form.
  """
  @spec get_cert_fingerprint() :: binary()
  def get_cert_fingerprint() do
    <<218, 225, 191, 40, 35, 120, 150, 183, 44, 117, 113, 254, 68, 136, 0, 164, 32, 0, 95, 220,
      113, 156, 179, 221, 80, 249, 148, 134, 26, 160, 116, 25>>
  end

  @doc """
  Creates new `t:Track.t/0`.
  """
  @spec get_track(:audio | :video) :: Track.t()
  def get_track(type \\ :audio) do
    stream_id = Track.stream_id()
    Track.new(type, stream_id)
  end
end

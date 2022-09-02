defmodule Membrane.WebRTC.Utils do
  @moduledoc false

  alias Membrane.WebRTC.Track
  alias ExSDP.Attribute.{FMTP, RTPMapping}

  @doc """
  Pairs RTP mappings (rtpmap) with corresponding format paramters (fmtp).
  """
  @spec pair_rtp_mappings_with_fmtp(Track.t()) :: [{RTPMapping.t(), FMTP.t()}]
  def pair_rtp_mappings_with_fmtp(track) do
    pt_to_fmtp = Map.new(track.fmtp, &{&1.pt, &1})
    Enum.map(track.rtp_mapping, &{&1, Map.get(pt_to_fmtp, &1.payload_type)})
  end

  @doc """
  Converts encoding name to its SDP string representation.
  """
  @spec encoding_name_to_string(atom()) :: String.t()
  def encoding_name_to_string(encoding_name) do
    case(encoding_name) do
      :VP8 -> "VP8"
      :H264 -> "H264"
      :OPUS -> "opus"
      x -> to_string(x)
    end
  end
end

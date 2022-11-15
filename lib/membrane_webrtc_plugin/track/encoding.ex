defmodule Membrane.WebRTC.Track.Encoding do
  @moduledoc """
  A struct holding a data passed via SDP about a possible encoding of a track
  """

  alias ExSDP.Attribute.{FMTP, RTCPFeedback}

  @type t :: %__MODULE__{
          payload_type: non_neg_integer(),
          name: String.t(),
          clock_rate: pos_integer(),
          rtx: %{payload_type: non_neg_integer(), rtx_time: non_neg_integer() | nil} | nil,
          red_payload_type: non_neg_integer(),
          audio_channels: pos_integer(),
          rtcp_feedback: MapSet.t(RTCPFeedback.t()),
          format_params: FMTP.t()
        }

  @enforce_keys [:payload_type, :name, :clock_rate]
  defstruct @enforce_keys ++
              [
                rtx: nil,
                red_payload_type: nil,
                audio_channels: nil,
                rtcp_feedback: MapSet.new(),
                format_params: nil
              ]
end

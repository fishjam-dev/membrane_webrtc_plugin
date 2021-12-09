defmodule Membrane.WebRTC.Extension.TWCC do
  @moduledoc false
  @behaviour Membrane.WebRTC.Extension

  alias ExSDP.Media
  alias ExSDP.Attribute.Extmap

  @name :twcc
  @uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
  @rtp_module Membrane.RTP.TWCCReceiver

  @impl true
  def compatible?(_encoding), do: true

  @impl true
  def get_name(), do: @name

  @impl true
  def get_uri(), do: @uri

  @impl true
  def get_rtp_module(twcc_id), do: %@rtp_module{twcc_id: twcc_id}

  @impl true
  def add_to_media(media, _extmap, :sendonly, _payload_types), do: media

  @impl true
  def add_to_media(media, id, _direction, payload_types) do
    media
    |> Media.add_attribute(%Extmap{id: id, uri: @uri, direction: :recvonly})
    |> Media.add_attributes(Enum.map(payload_types, &"rtcp-fb:#{&1} transport-cc"))
  end
end

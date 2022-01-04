defmodule Membrane.WebRTC.Extension.Rid do
  @moduledoc """
  Module implementing `Membrane.WebRTC.Extension` behaviour for RTP Stream Identifier RTP Header extension.

  This extension is described in RFC 8852.
  """
  @behaviour Membrane.WebRTC.Extension

  alias ExSDP.Media
  alias ExSDP.Attribute.Extmap

  @name :rid
  @uri "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"

  @impl true
  def compatible?(_encoding), do: true

  @impl true
  def get_name(), do: @name

  @impl true
  def get_uri(), do: @uri

  # there is no module parsing RTP headers against this extension as
  # for the whole session mid for same buffer will be the same.
  # It is used only in handler for `:new_rtp_stream` notification.
  @impl true
  def get_rtp_module(_rid_id), do: :no_rtp_module

  @impl true
  def add_to_media(media, id, _direction, _payload_types),
    do: Media.add_attribute(media, %Extmap{id: id, uri: @uri})
end

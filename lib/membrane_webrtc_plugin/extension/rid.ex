defmodule Membrane.WebRTC.Extension.Rid do
  @moduledoc false
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

  @impl true
  def get_rtp_module(_rid_id), do: :no_rtp_module

  @impl true
  def add_to_media(media, id, _direction, _payload_types),
    do: Media.add_attribute(media, %Extmap{id: id, uri: @uri})
end

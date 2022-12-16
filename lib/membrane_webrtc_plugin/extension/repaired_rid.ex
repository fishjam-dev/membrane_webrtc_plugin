defmodule Membrane.WebRTC.Extension.RepairedRid do
  @moduledoc """
  Module implementing `Membrane.WebRTC.Extension` behaviour for Repair RTP Stream Identifier RTP Header extension.

  This extension is described in RFC 8852.
  """
  @behaviour Membrane.WebRTC.Extension

  alias ExSDP.Attribute.Extmap
  alias ExSDP.Media
  alias Membrane.WebRTC.Extension

  @name :repaired_rid
  @uri "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"

  @impl true
  def new(opts \\ Keyword.new()),
    do: %Extension{module: __MODULE__, rtp_opts: opts, uri: @uri, name: @name}

  @impl true
  def compatible?(_encoding), do: true

  # there is no module parsing RTP headers against this extension as
  # for the whole session mid for same buffer will be the same.
  # It is used only in handler for `:new_rtp_stream` notification.
  @impl true
  def get_rtp_module(_rid_id, _opts, _track_type), do: :no_rtp_module

  @impl true
  def add_to_media(media, id, _direction, _payload_types),
    do: Media.add_attribute(media, %Extmap{id: id, uri: @uri})

  @impl true
  def uri, do: @uri
end

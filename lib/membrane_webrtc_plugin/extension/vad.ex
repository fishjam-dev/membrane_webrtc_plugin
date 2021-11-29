defmodule Membrane.WebRTC.Extension.VAD do
  @moduledoc false
  @behaviour Membrane.WebRTC.Extension

  alias ExSDP.Media
  alias ExSDP.Attribute.Extmap

  @name :vad
  @uri "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
  @attributes ["vad=on"]
  @rtp_module Membrane.RTP.VAD

  @impl true
  def compatible?(encoding), do: encoding == :OPUS

  @impl true
  def get_name(), do: @name

  @impl true
  def get_uri(), do: @uri

  @impl true
  def get_rtp_module(), do: @rtp_module

  @impl true
  def add_to_media(media, id, _direction, _pt),
    do:
      Media.add_attribute(media, %Extmap{
        id: id,
        uri: @uri,
        attributes: @attributes
      })
end

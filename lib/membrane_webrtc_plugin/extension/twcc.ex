defmodule Membrane.WebRTC.Extension.TWCC do
  @moduledoc """
  Module implementing `Membrane.WebRTC.Extension` behaviour for Transport-wide Congestion Control RTP Header extension.

  This extension is described at https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01.
  """
  @behaviour Membrane.WebRTC.Extension

  alias ExSDP.Media
  alias ExSDP.Attribute.Extmap
  alias Membrane.WebRTC.Extension

  @name :twcc
  @uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
  @rtp_module Membrane.RTP.TWCCReceiver

  @impl true
  def new(opts \\ Keyword.new()), do: %Extension{module: __MODULE__, rtp_opts: opts}

  @impl true
  def compatible?(_encoding), do: true

  @impl true
  def get_name(), do: @name

  @impl true
  def get_uri(), do: @uri

  @impl true
  def get_rtp_module(twcc_id, _rtp_opts), do: %@rtp_module{twcc_id: twcc_id}

  @impl true
  def add_to_media(media, id, _direction, payload_types) do
    media
    |> Media.add_attribute(%Extmap{id: id, uri: @uri})
    |> Media.add_attributes(Enum.map(payload_types, &"rtcp-fb:#{&1} transport-cc"))
  end
end

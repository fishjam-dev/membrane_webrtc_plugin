defmodule Membrane.WebRTC.Extension do
  @moduledoc """
  A module that provides mappings between `ExSDP.Attribute.Extmap` and modules implementing
  `Membrane.WebRTC.Extension` behaviour.
  """
  alias ExSDP.Media
  alias ExSDP.Attribute.{FMTP, Extmap}
  alias Membrane.{RTP, WebRTC}

  @type t :: module()
  @type maybe_t :: t() | :not_supported

  @doc """
  Returns a boolean indicating whether an extension is compatible with given encoding.
  """
  @callback compatible?(WebRTC.Track.encoding()) :: boolean()

  @doc """
  Returns an atom identifying the extension in `Membrane.RTP.SessionBin`.
  """
  @callback get_name() :: RTP.SessionBin.rtp_extension_name_t()

  @doc """
  Returns a URI that identifies extension in SDP.
  """
  @callback get_uri() :: String.t()

  @doc """
  Returns a module that implements the extension in `Membrane.RTP.SessionBin`.
  """
  @callback get_rtp_module() :: Membrane.ParentSpec.child_spec_t()

  @doc """
  Adds information about extension to an SDP media.
  """
  @callback add_to_media(
              Media.t(),
              Extmap.extension_id(),
              Extmap.direction(),
              [FMTP.payload_type_t()]
            ) ::
              Media.t()

  @doc """
  Given a list of supported extensions, checks if there is an extension that corresponds to
  given `Extmap` and encoding.
  """
  @spec supported?([t()], Extmap.t(), atom()) :: boolean()
  def supported?(extensions, %Extmap{uri: uri}, encoding),
    do: Enum.any?(extensions, &(&1.get_uri() == uri and &1.compatible?(encoding)))

  @doc """
  Given a list of supported extensions, returns an extension that corresponds to given `Extmap`
  or `:not_supported` if there is no such extension.
  """
  @spec from_extmap([t()], Extmap.t()) :: maybe_t()
  def from_extmap(extensions, %Extmap{uri: uri}),
    do: Enum.find(extensions, :not_supported, &(&1.get_uri() == uri))

  @doc """
  Given an SDP media, a list of supported extensions and supported `Extmap`s, adds corresponding
  extensions to the media.
  """
  @spec add_to_media(Media.t(), [t()], [Extmap.t()], Extmap.direction(), [FMTP.payload_type_t()]) ::
          Media.t()
  def add_to_media(media, _extensions, [], _direction, _pt), do: media

  def add_to_media(media, extensions, [extmap | rest], direction, payload_types) do
    extension = from_extmap(extensions, extmap)

    media
    |> extension.add_to_media(extmap.id, direction, payload_types)
    |> add_to_media(extensions, rest, direction, payload_types)
  end

  @doc """
  Given a list of supported extensions, maps a supported `Extmap` to an `RTP.SessionBin.rtp_extension_t()`.
  """
  @spec as_rtp_extension([t()], Extmap.t()) :: RTP.SessionBin.rtp_extension_options_t()
  def as_rtp_extension(extensions, extmap) do
    extension = from_extmap(extensions, extmap)
    {extension.get_name(), extmap.id, extension.get_rtp_module()}
  end

  @doc """
  Given a list of supported extensions and a supported `Extmap`, generates a mapping from a name provided
  by an extension to an ID provided by the `Extmap`.
  """
  @spec as_rtp_mapping([t()], Extmap.t()) ::
          {RTP.SessionBin.rtp_extension_name_t(), Extmap.extension_id()}
  def as_rtp_mapping(extensions, extmap) do
    extension = from_extmap(extensions, extmap)
    {extension.get_name(), extmap.id}
  end
end

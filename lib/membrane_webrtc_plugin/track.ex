defmodule Membrane.WebRTC.Track do
  @moduledoc """
  Module representing a WebRTC track.
  """
  alias ExSDP.Attribute.{Extmap, FMTP, RTPMapping}
  alias ExSDP.Media
  alias Membrane.WebRTC.{Extension, Utils}

  require Membrane.Logger

  @supported_rids ["l", "m", "h"]

  @enforce_keys [
    :type,
    :stream_id,
    :id,
    :name,
    :mid,
    :rids,
    :rtp_mapping,
    :fmtp,
    :status,
    :extmaps
  ]
  defstruct @enforce_keys ++ [ssrc: nil, encoding: nil, rid_to_ssrc: %{}]

  @type id :: String.t()
  @type encoding :: :OPUS | :H264 | :VP8

  @type t :: %__MODULE__{
          type: :audio | :video,
          stream_id: String.t(),
          id: id,
          name: String.t(),
          ssrc: RTP.ssrc_t() | [RTP.ssrc_t()],
          encoding: encoding,
          status: :pending | :ready | :linked | :disabled,
          mid: binary(),
          rids: [String.t()] | nil,
          rid_to_ssrc: %{},
          rtp_mapping: RTPMapping.t() | [RTPMapping.t()],
          fmtp: FMTP.t() | [FMTP.t()],
          extmaps: [Extmap]
        }

  @doc """
  Creates a new track.

  Tracks belonging to the same stream should have the same `stream_id`,
  that can be generated with `stream_id/0`.
  """
  @spec new(:audio | :video, stream_id :: String.t(),
          id: String.t(),
          name: String.t(),
          ssrc: RTP.ssrc_t() | [RTP.ssrc_t()] | nil,
          encoding: encoding,
          mid: non_neg_integer(),
          rids: [String.t()] | nil,
          rtp_mapping: RTPMapping.t(),
          status: :pending | :ready | :linked | :disabled,
          fmtp: FMTP.t(),
          extmaps: [Extmap]
        ) :: t
  def new(type, stream_id, opts \\ []) do
    id = Keyword.get(opts, :id, Base.encode16(:crypto.strong_rand_bytes(8)))
    name = Keyword.get(opts, :name, "#{id}-#{type}-#{stream_id}")

    %__MODULE__{
      type: type,
      stream_id: stream_id,
      id: id,
      name: name,
      ssrc: Keyword.get(opts, :ssrc, :crypto.strong_rand_bytes(4)),
      encoding: Keyword.get(opts, :encoding),
      rtp_mapping: Keyword.get(opts, :rtp_mapping),
      mid: Keyword.get(opts, :mid),
      rids: Keyword.get(opts, :rids),
      status: Keyword.get(opts, :status, :ready),
      fmtp: Keyword.get(opts, :fmtp),
      extmaps: Keyword.get(opts, :extmaps, [])
    }
  end

  @doc """
  Generates stream id, that can be used to mark tracks belonging to the same stream.
  """
  @spec stream_id() :: String.t()
  def stream_id(), do: UUID.uuid4()

  @doc """
  Given a list of new tracks and a list of already added tracks,
  adds ssrcs to the new tracks.
  """
  @spec add_ssrc(t | [t], [t]) :: [t]
  def add_ssrc(tracks, present_tracks) do
    restricted_ssrcs = MapSet.new(present_tracks, & &1.ssrc)

    {tracks, _restricted_ssrcs} =
      tracks
      |> Bunch.listify()
      |> Enum.map_reduce(restricted_ssrcs, fn track, restricted_ssrcs ->
        ssrc =
          fn -> :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() end
          |> Stream.repeatedly()
          |> Enum.find(&(&1 not in restricted_ssrcs))

        {%__MODULE__{track | ssrc: ssrc}, MapSet.put(restricted_ssrcs, ssrc)}
      end)

    tracks
  end

  @doc """
  Creates `t:t/0` from SDP m-line with random track id and stream id.
  """
  @spec from_sdp_media(ExSDP.Media.t()) :: t()
  def from_sdp_media(sdp_media) do
    from_sdp_media(sdp_media, Base.encode16(:crypto.strong_rand_bytes(8)), stream_id())
  end

  @doc """
  Creates `t:t/0` from SDP m-line with specific track id and stream id.
  """
  @spec from_sdp_media(ExSDP.Media.t(), id(), String.t()) :: t()
  def from_sdp_media(sdp_media, id, stream_id) do
    rids =
      sdp_media
      |> Media.get_attributes("rid")
      |> Enum.map(fn {_attr, rid} ->
        # example from sdp
        # a=rid:h send
        # by rid we mean "h send"
        rid |> String.split(" ", parts: 2) |> hd()
      end)

    rids = if(rids == [], do: nil, else: rids)

    ssrc = Media.get_attribute(sdp_media, :ssrc)
    # this function is being called only for inbound media
    # therefore, if SSRC is `nil` `sdp_media` must represent simulcast track
    ssrc = if ssrc == nil, do: [], else: ssrc.id

    status =
      if Media.get_attribute(sdp_media, :inactive) != nil do
        :disabled
      else
        :ready
      end

    opts = [
      id: id,
      ssrc: ssrc,
      mid: Media.get_attribute(sdp_media, :mid) |> elem(1),
      rids: rids,
      rtp_mapping: Media.get_attributes(sdp_media, :rtpmap),
      fmtp: Media.get_attributes(sdp_media, :fmtp),
      status: status,
      extmaps: Media.get_attributes(sdp_media, :extmap)
    ]

    new(sdp_media.type, stream_id, opts)
  end

  @doc """
  Modifies track properties according to provided constraints.

  In particular, after setting constraints, track can be disabled.
  """
  @spec set_constraints(t(), :inbound | :outbound, map()) :: t()
  def set_constraints(track, track_type, constraints) do
    %__MODULE__.Constraints{
      simulcast?: simulcast?,
      codecs_filter: codecs_filter,
      enabled_extensions: enabled_extensions,
      endpoint_direction: endpoint_direction
    } = constraints

    selected_rtp_fmtp_pair =
      track
      |> Utils.pair_rtp_mappings_with_fmtp()
      |> Enum.filter(codecs_filter)
      |> List.first()

    if selected_rtp_fmtp_pair == nil do
      raise("All payload types in SDP offer are unsupported")
    end

    {rtp_mapping, fmtp} = selected_rtp_fmtp_pair

    status =
      cond do
        # if simulcast was offered but we don't accept it, turn track off
        # this is not compliant with WebRTC standard as we should only
        # remove simulcast attributes and be prepared to receive one
        # encoding but in such a case browser changes SSRC after ICE restart
        # and we cannot handle this at the moment
        track.rids != nil and simulcast? == false ->
          Membrane.Logger.debug("""
          Disabling track with id: #{inspect(track.id)} of type: #{inspect(track_type)}.
          Reason: simulcast track but EndpointBin set to not accept simulcast.
          """)

          raise RuntimeError, message: "Simulcast was offered, but it's not supported"

        # enforce rid values
        is_list(track.rids) and Enum.any?(track.rids, &(&1 not in @supported_rids)) ->
          Membrane.Logger.debug("""
          Disabling track with id: #{inspect(track.id)} of type: #{inspect(track_type)}.
          Reason: there is unsupported rid in #{inspect(track.rids)}. Supported rids: #{inspect(@supported_rids)}.
          """)

          :disabled

        # check direction
        endpoint_direction == :sendonly and track_type == :inbound ->
          Membrane.Logger.debug("""
          Disabling track with id: #{inspect(track.id)} of type: #{inspect(track_type)}.
          Reason: EndpointBin is set to #{inspect(endpoint_direction)}.
          """)

          :disabled

        true ->
          track.status
      end

    encoding = encoding_to_atom(rtp_mapping.encoding)

    extmaps = Enum.filter(track.extmaps, &Extension.supported?(enabled_extensions, &1, encoding))

    %__MODULE__{
      track
      | encoding: encoding,
        extmaps: extmaps,
        fmtp: fmtp,
        rtp_mapping: rtp_mapping,
        status: status
    }
  end

  @spec to_otel_data(t()) :: String.t()
  def to_otel_data(%__MODULE__{rids: nil} = track),
    do: "{id: #{track.id}, mid: #{track.mid}, encoding: #{track.encoding}}"

  def to_otel_data(%__MODULE__{} = track) do
    rids = Enum.join(track.rids, ", ")
    "{id: #{track.id}, mid: #{track.mid}, encoding: #{track.encoding}, rids: [#{rids}]}"
  end

  defp encoding_to_atom(encoding_name) do
    case encoding_name do
      "opus" -> :OPUS
      "VP8" -> :VP8
      "H264" -> :H264
      encoding -> raise "Not supported encoding: #{encoding}"
    end
  end
end

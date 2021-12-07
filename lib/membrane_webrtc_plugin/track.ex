defmodule Membrane.WebRTC.Track do
  @moduledoc """
  Module representing a WebRTC track.
  """
  alias ExSDP.Attribute.{RTPMapping, FMTP, Extmap}

  @enforce_keys [
    :type,
    :stream_id,
    :id,
    :name,
    :mid,
    :rid,
    :rtp_mapping,
    :fmtp,
    :status,
    :extmaps
  ]
  defstruct @enforce_keys ++ [ssrc: nil, encoding: nil]

  @type id :: String.t()
  @type encoding :: :OPUS | :H264 | :VP8

  @type t :: %__MODULE__{
          type: :audio | :video,
          stream_id: String.t(),
          id: id,
          name: String.t(),
          ssrc: RTP.ssrc_t(),
          encoding: encoding,
          status: :pending | :ready | :linked | :disabled,
          mid: non_neg_integer(),
          rid: [String.t()],
          rtp_mapping: RTPMapping,
          fmtp: FMTP,
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
          ssrc: RTP.ssrc_t(),
          encoding: encoding,
          mid: non_neg_integer(),
          rids: [String.t()],
          rtp_mapping: RTPMapping,
          status: :pending | :ready | :linked | :disabled,
          fmtp: FMTP,
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
      rid: Keyword.get(opts, :rids),
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
end

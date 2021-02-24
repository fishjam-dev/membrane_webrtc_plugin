defmodule Membrane.WebRTC.Track do
  @enforce_keys [:type, :stream_id, :id, :name, :timestamp]
  defstruct @enforce_keys ++ [ssrc: nil, encoding: nil, enabled?: true]

  def new(type, stream_id, opts \\ []) do
    id = Keyword.get(opts, :id, Base.encode16(:crypto.strong_rand_bytes(8)))
    name = Keyword.get(opts, :name, "#{id}-#{type}-#{stream_id}")

    %__MODULE__{
      type: type,
      stream_id: stream_id,
      id: id,
      name: Keyword.get(opts, :name, name),
      ssrc: Keyword.get(opts, :ssrc),
      encoding: Keyword.get(opts, :encoding),
      timestamp: System.monotonic_time()
    }
  end

  def stream_id(), do: UUID.uuid4()

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

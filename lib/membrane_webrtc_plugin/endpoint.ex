defmodule Membrane.WebRTC.Endpoint do
  @moduledoc """
  Module representing a WebRTC connection.
  """
  alias Membrane.WebRTC.Track

  @type id() :: any()
  @type type() :: :screensharing | :participant

  @type t :: %__MODULE__{
          id: id(),
          type: :participant | :screensharing,
          tracks: %{
            audio_tracks: %{Track.id() => [Track.t()]},
            video_tracks: %{Track.id() => [Track.t()]}
          }
        }

  defstruct id: nil, type: :participant, tracks: %{audio_tracks: %{}, video_tracks: %{}}

  @spec new(id :: id(), type :: type(), tracks :: [Track.t()]) :: Endpoint.t()
  def new(id, type, tracks) do
    {audio_tracks, video_tracks} =
      Enum.reduce(tracks, {%{}, %{}}, fn
        %Track{id: id, type: :audio} = track, {audio_tracks, video_tracks} ->
          {Map.put(audio_tracks, id, track), video_tracks}

        %Track{id: id, type: :video} = track, {audio_tracks, video_tracks} ->
          {audio_tracks, Map.put(video_tracks, id, track)}
      end)

    tracks = %{audio_tracks: audio_tracks, video_tracks: video_tracks}
    %__MODULE__{id: id, type: type, tracks: tracks}
  end

  @spec get_audio_tracks(endpoint :: Endpoint.t()) :: [Track]
  def get_audio_tracks(endpoint), do: Map.values(endpoint.tracks.audio_tracks)

  @spec get_video_tracks(ednpoint :: Endpoint.t()) :: [Track]
  def get_video_tracks(endpoint), do: Map.values(endpoint.tracks.video_tracks)

  @spec get_track_by_id(endpoint :: Endpoint.t(), id :: Track.id()) :: Track | nil
  def get_track_by_id(endpoint, id) do
    endpoint.tracks.audio_tracks[id] || endpoint.tracks.video_tracks[id]
  end

  @doc """
  Gets all tracks.
  """
  @spec get_tracks(endpoint :: Endpoint.t()) :: [Track]
  def get_tracks(endpoint),
    do: Map.values(endpoint.tracks.audio_tracks) ++ Map.values(endpoint.tracks.video_tracks)

  @spec update_track_encoding(endpoint :: Endpoint.t(), track_id :: Track.id(), encoding :: atom) ::
          Endpoint.t()
  def update_track_encoding(endpoint, track_id, value) do
    cond do
      Map.has_key?(endpoint.tracks.audio_tracks, track_id) ->
        endpoint.tracks.audio_tracks
        update_in(endpoint.tracks.audio_tracks[track_id], &%Track{&1 | encoding: value})

      Map.has_key?(endpoint.tracks.video_tracks, track_id) ->
        update_in(endpoint.tracks.video_tracks[track_id], &%Track{&1 | encoding: value})
    end
  end
end

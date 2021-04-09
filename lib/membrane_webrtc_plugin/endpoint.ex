defmodule Membrane.WebRTC.Endpoint do
  @moduledoc """
  Module representing a WebRTC connection.
  """
  alias Membrane.WebRTC.Track

  @type t :: %__MODULE__{
          id: any(),
          type: :participant | :screensharing,
          tracks: %{audio_tracks: %{}, video_tracks: %{}}
        }

  defstruct id: nil, type: :participant, tracks: %{audio_tracks: %{}, video_tracks: %{}}

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

  def get_audio_tracks(endpoint), do: Map.values(endpoint.tracks.audio_tracks)

  def get_video_tracks(endpoint), do: Map.values(endpoint.tracks.video_tracks)

  def get_track_by_id(endpoint, id) do
    endpoint.tracks.audio_tracks[id] || endpoint.tracks.video_tracks[id]
  end

  def get_tracks(endpoint),
    do: Map.values(endpoint.tracks.audio_tracks) ++ Map.values(endpoint.tracks.video_tracks)

  def update_track(endpoint, id, value) do
    cond do
      Map.has_key?(endpoint.tracks.audio_tracks, id) ->
        endpoint.tracks.audio_tracks
        update_in(endpoint.tracks.audio_tracks[id], &%Track{&1 | encoding: value})

      Map.has_key?(endpoint.tracks.video_tracks, id) ->
        update_in(endpoint.tracks.video_tracks[id], &%Track{&1 | encoding: value})
    end
  end
end

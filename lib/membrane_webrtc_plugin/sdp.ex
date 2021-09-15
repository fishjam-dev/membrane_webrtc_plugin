defmodule Membrane.WebRTC.SDP do
  @moduledoc """
  Module containing helper functions for creating SPD offer.
  """

  alias ExSDP.Attribute.{RTPMapping, MSID, SSRC, FMTP, Group}
  alias ExSDP.{ConnectionData, Media}
  alias Membrane.WebRTC.Track

  @type fingerprint :: {ExSDP.Attribute.hash_function(), binary()}

  @doc """
  Creates Unified Plan SDP answer.

  The mandatory options are:
  - ice_ufrag - ICE username fragment
  - ice_pwd - ICE password
  - fingerprint - DTLS fingerprint
  - inbound_tracks - list of inbound tracks
  - outbound_tracks - list of outbound tracks
  - mappings - dictionary where keys are tracks_id and value are mapping got from SDP offer.

  Additionally accepts audio_codecs and video_codecs options,
  that should contain lists of SDP attributes for desired codecs,
  for example:

      video_codecs: [
        %RTPMapping{payload_type: 98, encoding: "VP9", clock_rate: 90_000}
      ]
  """
  @spec create_answer(
          ice_ufrag: String.t(),
          ice_pwd: String.t(),
          fingerprint: fingerprint(),
          audio_codecs: [ExSDP.Attribute.t()],
          video_codecs: [ExSDP.Attribute.t()],
          inbound_tracks: [Track.t()],
          outbound_tracks: [Track.t()]
        ) :: ExSDP.t()
  def create_answer(opts) do
    inbound_tracks = Keyword.fetch!(opts, :inbound_tracks) |> Enum.sort_by(& &1.timestamp)
    outbound_tracks = Keyword.fetch!(opts, :outbound_tracks) |> Enum.sort_by(& &1.timestamp)
    mids = Enum.map(inbound_tracks ++ outbound_tracks, & &1.mid)

    config = %{
      ice_ufrag: Keyword.fetch!(opts, :ice_ufrag),
      ice_pwd: Keyword.fetch!(opts, :ice_pwd),
      fingerprint: Keyword.fetch!(opts, :fingerprint),
      codecs: %{
        audio: Keyword.get(opts, :audio_codecs, []),
        video: Keyword.get(opts, :video_codecs, [])
      }
    }

    attributes = [
      %Group{semantics: "BUNDLE", mids: mids}
    ]

    %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
    |> ExSDP.add_attributes(attributes)
    |> add_tracks(inbound_tracks, outbound_tracks, config)
  end

  defp encoding_name_to_string(encoding_name) do
    case(encoding_name) do
      :VP8 -> "VP8"
      :H264 -> "H264"
      :OPUS -> "opus"
      x -> to_string(x)
    end
  end

  defp add_tracks(sdp, inbound_tracks, outbound_tracks, config) do
    inbound_tracks = Enum.map(inbound_tracks, &{&1, create_sdp_media(&1, :recvonly, config)})

    outbound_tracks = Enum.map(outbound_tracks, &{&1, create_sdp_media(&1, :sendonly, config)})

    tracks =
      (inbound_tracks ++ outbound_tracks)
      |> Enum.sort_by(fn {track, _media} -> Integer.parse(track.mid) end)
      |> Enum.map(fn {_track, media} -> media end)

    ExSDP.add_media(sdp, tracks)
  end

  defp add_standard_extensions(media) do
    case media.type do
      :audio ->
        media
        |> Media.add_attribute("extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level vad=on")

      _media ->
        media
    end
  end

  defp create_sdp_media(track, direction, config) do
    codecs = config.codecs[track.type]

    track_data = track.rtp_mapping

    payload_type =
      if Map.has_key?(track_data, :payload_type),
        do: [track_data.payload_type],
        else: get_payload_types(codecs)

    %Media{
      Media.new(track.type, 9, "UDP/TLS/RTP/SAVPF", payload_type)
      | connection_data: [%ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> Media.add_attributes([
      if(track.status === :disabled, do: :inactive, else: direction),
      {:ice_ufrag, config.ice_ufrag},
      {:ice_pwd, config.ice_pwd},
      {:ice_options, "trickle"},
      {:fingerprint, config.fingerprint},
      {:setup, if(direction == :recvonly, do: :passive, else: :active)},
      {:mid, track.mid},
      MSID.new(track.stream_id),
      :rtcp_mux
    ])
    |> Media.add_attributes([track.rtp_mapping, track.fmtp])
    |> add_standard_extensions()
    |> add_extensions(track.type, payload_type)
    |> add_ssrc(track)
  end

  defp add_extensions(media, :audio, _pt), do: media

  defp add_extensions(media, :video, pt) do
    media
    |> Media.add_attributes(Enum.map(pt, &"rtcp-fb:#{&1} ccm fir"))
    |> Media.add_attribute(:rtcp_rsize)
  end

  defp add_ssrc(media, %Track{ssrc: nil}), do: media

  defp add_ssrc(media, track),
    do:
      Media.add_attributes(media, [
        %SSRC{id: track.ssrc, attribute: "cname", value: track.name},
        %SSRC{id: track.ssrc, attribute: "label", value: track.id}
      ])

  defp get_payload_types(codecs) do
    Enum.flat_map(codecs, fn
      %RTPMapping{payload_type: pt} -> [pt]
      _attr -> []
    end)
  end

  defp encoding_to_atom(encoding_name) do
    case encoding_name do
      "opus" -> :OPUS
      "VP8" -> :VP8
      "H264" -> :H264
      encoding -> raise "Not supported encoding: #{encoding}"
    end
  end

  defp get_recvonly_media(sdp, filter_codecs) do
    recv_only_sdp_media = filter_sdp_media(sdp, &(:recvonly in &1.attributes))
    Enum.map(recv_only_sdp_media, &get_mid_type_mappings_from_sdp_media(&1, filter_codecs))
  end

  defp update_mapping_and_mid_for_track(track, mappings) do
    encoding_string = encoding_name_to_string(track.encoding)

    mapping =
      Enum.find(mappings.rtp_fmtp_mappings, fn {rtp, _fmtp} ->
        rtp.encoding === encoding_string
      end)

    if mapping === nil do
      %{track | mid: mappings.mid, status: :disabled}
    else
      {rtp, fmtp} = mapping
      %{track | mid: mappings.mid, rtp_mapping: rtp, fmtp: fmtp}
    end
  end

  @spec filter_mappings({RTPMapping, FMTP}) :: boolean()
  def filter_mappings(rtp_fmtp_pair) do
    {rtp, fmtp} = rtp_fmtp_pair

    case rtp.encoding do
      "opus" -> true
      "VP8" -> true
      "H264" -> fmtp.profile_level_id === 0x42E01F
      _unsupported_codec -> false
    end
  end

  defp get_mid_type_mappings_from_sdp_media(sdp_media, filter_codecs) do
    media_type = sdp_media.type
    {:mid, mid} = Media.get_attribute(sdp_media, :mid)
    rtp_mappings = for %RTPMapping{} = rtp_mapping <- sdp_media.attributes, do: rtp_mapping
    fmtp_mappings = for %FMTP{} = fmtp_mapping <- sdp_media.attributes, do: fmtp_mapping

    pt_to_fmtp = Map.new(fmtp_mappings, &{&1.pt, &1})

    rtp_fmtp_pairs = Enum.map(rtp_mappings, &{&1, Map.get(pt_to_fmtp, &1.payload_type)})

    new_rtp_fmtp_pairs = Enum.filter(rtp_fmtp_pairs, &filter_codecs.(&1))

    if new_rtp_fmtp_pairs === [] do
      %{rtp_fmtp_mappings: rtp_fmtp_pairs, mid: mid, media_type: media_type, disabled?: true}
    else
      %{rtp_fmtp_mappings: new_rtp_fmtp_pairs, mid: mid, media_type: media_type, disabled?: false}
    end
  end

  @spec get_tracks(ExSDP.t(), any, [Track.t()], [Track.t()]) ::
          {[Track.t()], [Track.t()], [Track.t()]}
  def get_tracks(sdp, filter_codecs, outbound_tracks, old_inbound_tracks) do
    send_only_sdp_media = filter_sdp_media(sdp, &(:sendonly in &1.attributes))

    stream_id = Track.stream_id()

    new_inbound_tracks =
      Enum.map(send_only_sdp_media, &create_track_from_sdp_media(&1, stream_id, filter_codecs))
      |> get_new_tracks(old_inbound_tracks)

    recv_only_sdp_media = get_recvonly_media(sdp, filter_codecs)
    outbound_tracks = get_outbound_tracks_updated(recv_only_sdp_media, outbound_tracks)

    {new_inbound_tracks, new_inbound_tracks ++ old_inbound_tracks, outbound_tracks}
  end

  defp get_outbound_tracks_updated(outbound_media, outbound_tracks) do
    audio_tracks = update_outbound_tracks_by_type(outbound_media, outbound_tracks, :audio)

    video_tracks = update_outbound_tracks_by_type(outbound_media, outbound_tracks, :video)

    updated_outbound_tracks = Map.merge(audio_tracks, video_tracks)
    Map.values(updated_outbound_tracks)
  end

  defp get_new_tracks(inbound_tracks, old_inbound_tracks) do
    known_ssrcs = Enum.map(old_inbound_tracks, fn track -> track.ssrc end)
    Enum.filter(inbound_tracks, &(&1.ssrc not in known_ssrcs))
  end

  # As the mid of outbound_track can change between SDP offers and different browser can have
  # different payload_type for the same codec, so after receiving each sdp offer we update each outbound_track rtp_mapping and mid
  # based on data we receive in sdp offer
  defp update_outbound_tracks_by_type(medias, tracks, type) do
    sort_mid = &if &1.mid != nil, do: Integer.parse(&1.mid), else: nil

    medias =
      Enum.filter(medias, &(&1.media_type === type))
      |> Enum.sort_by(sort_mid)

    tracks = Enum.filter(tracks, &(&1.type === type)) |> Enum.sort_by(sort_mid)

    Enum.zip(medias, tracks)
    |> Map.new(fn {media, track} ->
      {track.id, update_mapping_and_mid_for_track(track, media)}
    end)
  end

  defp create_track_from_sdp_media(sdp_media, stream_id, filter_codecs) do
    media_type = sdp_media.type

    ssrc = Media.get_attribute(sdp_media, :ssrc).id

    %{rtp_fmtp_mappings: [{rtp, fmtp} | _], mid: mid, disabled?: disabled} =
      get_mid_type_mappings_from_sdp_media(sdp_media, filter_codecs)

    opts = [
      ssrc: ssrc,
      encoding: encoding_to_atom(rtp.encoding),
      mid: mid,
      rtp_mapping: rtp,
      fmtp: fmtp,
      status: if(disabled, do: :disabled, else: :ready)
    ]

    Track.new(media_type, stream_id, opts)
  end

  @spec filter_sdp_media(ExSDP.t(), any) :: [Media.t()]
  def filter_sdp_media(sdp, filter_function), do: Enum.filter(sdp.media, &filter_function.(&1))
end

defmodule Membrane.WebRTC.SDP do
  @moduledoc """
  Module containing helper functions for creating SPD offer.
  """

  alias ExSDP.Attribute.{RTPMapping, MSID, SSRC, FMTP, Group}
  alias ExSDP.{ConnectionData, Media}
  alias Membrane.WebRTC.{Extension, Track}

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
  """
  @spec create_answer(
          ice_ufrag: String.t(),
          ice_pwd: String.t(),
          fingerprint: fingerprint(),
          extensions: [Extension.t()],
          inbound_tracks: [Track.t()],
          outbound_tracks: [Track.t()]
        ) :: ExSDP.t()
  def create_answer(opts) do
    inbound_tracks = Keyword.fetch!(opts, :inbound_tracks)
    outbound_tracks = Keyword.fetch!(opts, :outbound_tracks)

    mids =
      Enum.map(inbound_tracks ++ outbound_tracks, & &1.mid)
      |> Enum.sort_by(&String.to_integer/1)

    config = %{
      ice_ufrag: Keyword.fetch!(opts, :ice_ufrag),
      ice_pwd: Keyword.fetch!(opts, :ice_pwd),
      fingerprint: Keyword.fetch!(opts, :fingerprint),
      extensions: Keyword.fetch!(opts, :extensions),
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
    inbound_media = Enum.map(inbound_tracks, &create_sdp_media(&1, :recvonly, config))
    outbound_media = Enum.map(outbound_tracks, &create_sdp_media(&1, :sendonly, config))
    media = Enum.sort_by(inbound_media ++ outbound_media, &String.to_integer(&1.attributes[:mid]))
    ExSDP.add_media(sdp, media)
  end

  defp create_sdp_media(track, direction, config) do
    payload_type = [track.rtp_mapping.payload_type]

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
      # We assume browser always send :actpass in SDP offer
      {:setup, :passive},
      {:mid, track.mid},
      MSID.new(track.stream_id),
      :rtcp_mux
    ])
    |> Media.add_attributes(
      if(track.fmtp == nil,
        do: [track.rtp_mapping],
        else: [track.rtp_mapping, track.fmtp]
      )
    )
    |> add_extensions(config.extensions, track, direction, payload_type)
    |> add_ssrc(track)
  end

  defp add_extensions(media, extensions, %Track{type: :audio} = track, direction, pt),
    do: Extension.add_to_media(media, extensions, track.extmaps, direction, pt)

  defp add_extensions(media, extensions, %Track{type: :video} = track, direction, pt) do
    media
    |> Extension.add_to_media(extensions, track.extmaps, direction, pt)
    |> Media.add_attributes(Enum.map(pt, &"rtcp-fb:#{&1} ccm fir"))
    |> Media.add_attribute(:rtcp_rsize)
  end

  defp add_ssrc(media, %Track{ssrc: nil}), do: media

  defp add_ssrc(media, track),
    do:
      Media.add_attributes(media, [
        %SSRC{id: track.ssrc, attribute: "cname", value: track.name}
      ])

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

  @spec get_tracks(
          sdp :: ExSDP.t(),
          codecs_filter :: ({RTPMapping, FMTP} -> boolean()),
          enabled_extensions :: [Extension.t()],
          old_inbound_tracks :: [Track.t()],
          outbound_tracks :: [Track.t()],
          mid_to_track_id :: %{}
        ) ::
          {new_inbound_tracks :: [Track.t()], inbound_tracks :: [Track.t()],
           outbound_tracks :: [Track.t()]}
  def get_tracks(
        sdp,
        codecs_filter,
        enabled_extensions,
        old_inbound_tracks,
        outbound_tracks,
        mid_to_track_id
      ) do
    send_only_sdp_media = Enum.filter(sdp.media, &(:sendonly in &1.attributes))

    stream_id = Track.stream_id()

    new_inbound_tracks =
      Enum.map(
        send_only_sdp_media,
        &create_track_from_sdp_media(
          &1,
          stream_id,
          codecs_filter,
          enabled_extensions,
          mid_to_track_id
        )
      )
      |> get_new_tracks(old_inbound_tracks)

    {removed_inbound_tracks, same_inbound_tracks} =
      update_inbound_tracks_status(old_inbound_tracks, mid_to_track_id)

    old_inbound_tracks = removed_inbound_tracks ++ same_inbound_tracks

    recv_only_sdp_media_data = get_media_by_attribute(sdp, codecs_filter, :recvonly)
    outbound_tracks = get_outbound_tracks_updated(recv_only_sdp_media_data, outbound_tracks)

    {new_inbound_tracks, removed_inbound_tracks, new_inbound_tracks ++ old_inbound_tracks,
     outbound_tracks}
  end

  defp update_inbound_tracks_status(old_inbound_tracks, mid_to_track_id),
    do:
      Enum.split_with(old_inbound_tracks, fn old_track ->
        Map.has_key?(mid_to_track_id, old_track.mid) or old_track.status == :disabled
      end)
      |> then(fn {same_tracks, tracks_to_update} ->
        Enum.map(tracks_to_update, &%{&1 | status: :disabled})
        |> then(&{&1, same_tracks})
      end)

  defp encoding_to_atom(encoding_name) do
    case encoding_name do
      "opus" -> :OPUS
      "VP8" -> :VP8
      "H264" -> :H264
      encoding -> raise "Not supported encoding: #{encoding}"
    end
  end

  defp get_media_by_attribute(sdp, codecs_filter, attribute) do
    media = Enum.filter(sdp.media, &(attribute in &1.attributes))
    Enum.map(media, &get_mid_type_mappings_from_sdp_media(&1, codecs_filter))
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

  defp get_new_tracks(inbound_tracks, old_inbound_tracks) do
    known_ids = Enum.map(old_inbound_tracks, fn track -> track.id end)
    Enum.filter(inbound_tracks, &(&1.id not in known_ids))
  end

  defp get_mid_type_mappings_from_sdp_media(sdp_media, codecs_filter) do
    media_type = sdp_media.type
    {:mid, mid} = Media.get_attribute(sdp_media, :mid)
    result = Enum.find(sdp_media.attributes, &(&1 == :inactive))
    disabled? = result != nil

    rtp_mappings = Media.get_attributes(sdp_media, :rtpmap)
    fmtp_mappings = Media.get_attributes(sdp_media, :fmtp)

    pt_to_fmtp = Map.new(fmtp_mappings, &{&1.pt, &1})
    rtp_fmtp_pairs = Enum.map(rtp_mappings, &{&1, Map.get(pt_to_fmtp, &1.payload_type)})
    new_rtp_fmtp_pairs = Enum.filter(rtp_fmtp_pairs, codecs_filter)

    if new_rtp_fmtp_pairs === [] do
      raise "All payload types in SDP offer are unsupported"
    else
      %{
        rtp_fmtp_mappings: new_rtp_fmtp_pairs,
        mid: mid,
        media_type: media_type,
        disabled?: disabled?
      }
    end
  end

  defp get_outbound_tracks_updated(outbound_media_data, outbound_tracks) do
    audio_tracks = update_outbound_tracks_by_type(outbound_media_data, outbound_tracks, :audio)

    video_tracks = update_outbound_tracks_by_type(outbound_media_data, outbound_tracks, :video)

    updated_outbound_tracks = Map.merge(audio_tracks, video_tracks)
    Map.values(updated_outbound_tracks)
  end

  # As the mid of outbound_track can change between SDP offers and different browser can have
  # different payload_type for the same codec, so after receiving each sdp offer we update each outbound_track rtp_mapping and mid
  # based on data we receive in sdp offer
  defp update_outbound_tracks_by_type(media_data, tracks, type) do
    sort_mid = &if &1.mid != nil, do: String.to_integer(&1.mid), else: nil

    media_data =
      Enum.filter(media_data, &(&1.media_type === type))
      |> Enum.sort_by(sort_mid)

    tracks = Enum.filter(tracks, &(&1.type === type)) |> Enum.sort_by(sort_mid)

    Enum.zip(media_data, tracks)
    |> Map.new(fn {media, track} ->
      {track.id, update_mapping_and_mid_for_track(track, media)}
    end)
  end

  defp create_track_from_sdp_media(
         sdp_media,
         stream_id,
         codecs_filter,
         enabled_extensions,
         mid_to_track_id
       ) do
    media_type = sdp_media.type

    ssrc = Media.get_attribute(sdp_media, :ssrc)
    ssrc = if ssrc == nil, do: nil, else: ssrc.id

    %{rtp_fmtp_mappings: [{rtp, fmtp} | _], mid: mid, disabled?: disabled} =
      get_mid_type_mappings_from_sdp_media(sdp_media, codecs_filter)

    encoding = encoding_to_atom(rtp.encoding)

    supported_extmaps =
      sdp_media
      |> Media.get_attributes(:extmap)
      |> Enum.filter(&Extension.supported?(enabled_extensions, &1, encoding))

    opts = [
      id: Map.get(mid_to_track_id, mid),
      ssrc: ssrc,
      encoding: encoding,
      mid: mid,
      rtp_mapping: rtp,
      fmtp: fmtp,
      status: if(disabled, do: :disabled, else: :ready),
      extmaps: supported_extmaps
    ]

    Track.new(media_type, stream_id, opts)
  end
end

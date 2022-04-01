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
  - extensions - list of webrtc extensions to use
  - inbound_tracks - list of inbound tracks
  - outbound_tracks - list of outbound tracks
  - ice_lite? - defines whether use ICE Lite or not
  """
  @spec create_answer(
          ice_ufrag: String.t(),
          ice_pwd: String.t(),
          fingerprint: fingerprint(),
          extensions: [Extension.t()],
          inbound_tracks: [Track.t()],
          outbound_tracks: [Track.t()],
          ice_lite?: boolean()
        ) :: ExSDP.t()
  def create_answer(opts) do
    inbound_tracks = Keyword.fetch!(opts, :inbound_tracks) |> filter_simulcast_tracks()
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

    attributes =
      [%Group{semantics: "BUNDLE", mids: mids}] ++
        if Keyword.get(opts, :ice_lite?), do: [:ice_lite], else: []

    %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
    |> ExSDP.add_attributes(attributes)
    |> add_tracks(inbound_tracks, outbound_tracks, config)
  end

  @doc """
  Remove from list all simulcast tracks, which aren't prototypes.
  """
  @spec filter_simulcast_tracks(inbound_tracks :: [Track.t()]) :: [Track.t()]
  def filter_simulcast_tracks(inbound_tracks) do
    inbound_tracks
    |> Enum.reduce(%{}, fn track, acc ->
      if not Map.has_key?(acc, track.mid) or simulcast_ssrc?(track.ssrc),
        do: Map.put(acc, track.mid, track),
        else: acc
    end)
    |> Enum.map(fn {_mid, track} -> track end)
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
    |> then(fn media ->
      if is_list(track.rids) and direction == :recvonly do
        # if this is an incoming simulcast track add RIDs else add SSRC
        add_rids(media, track)
      else
        add_ssrc(media, track, direction)
      end
    end)
  end

  defp add_extensions(media, extensions, %Track{type: :audio} = track, direction, pt),
    do: Extension.add_to_media(media, extensions, track.extmaps, direction, pt)

  defp add_extensions(media, extensions, %Track{type: :video} = track, direction, pt) do
    media
    |> Extension.add_to_media(extensions, track.extmaps, direction, pt)
    |> Media.add_attributes(Enum.map(pt, &"rtcp-fb:#{&1} ccm fir"))
    |> Media.add_attribute(:rtcp_rsize)
  end

  defp add_rids(media, track) do
    rids = Enum.join(track.rids, ";")

    track.rids
    |> Enum.reduce(media, fn rid, media ->
      Media.add_attribute(media, "rid:#{rid} recv")
    end)
    |> Media.add_attribute("simulcast:recv #{rids}")
  end

  defp add_ssrc(media, track, direction) do
    if direction == :recvonly do
      # for :recvonly tracks browser will choose SSRC
      media
    else
      # we don't have to handle case in which `track.ssrc` is a list of
      # SSRCs as such case means `track` is a simulcast track and we don't add
      # any SSRC for simulcast tracks only RIDs
      Media.add_attributes(media, [
        %SSRC{id: track.ssrc, attribute: "cname", value: track.name}
      ])
    end
  end

  @doc """
  Default value for filter_codecs option in `Membrane.WebRTC.EndpointBin`.
  """
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

  @doc """
  Returns how tracks have changed based on SDP offer.

  Function returns four-element tuple, which contains list of new tracks, list of removed tracks, list of all inbound tracks
  and list of all outbound tracks.

  Function arguments:
  * sdp - SDP offer
  * codecs_filter - function which will filter SDP m-line by codecs
  * enabled_extensions - list of WebRTC extensions that should be enabled for tracks
  * old_inbound_tracks - list of old inbound tracks
  * outbound_tracks - list of outbound_tracks
  * mid_to_track_id - map of mid to track_id for all active inbound_tracks
  * simulcast? - whether to accept simulcast or not
  """
  @spec get_tracks(
          sdp :: ExSDP.t(),
          codecs_filter :: ({RTPMapping, FMTP} -> boolean()),
          enabled_extensions :: [Extension.t()],
          old_inbound_tracks :: [Track.t()],
          outbound_tracks :: [Track.t()],
          mid_to_track_id :: %{String.t() => Track.id()},
          simulcast? :: boolean()
        ) ::
          {new_inbound_tracks :: [Track.t()], removed_inbound_tracks :: [Track.t()],
           inbound_tracks :: [Track.t()], outbound_tracks :: [Track.t()]}
  def get_tracks(
        sdp,
        codecs_filter,
        enabled_extensions,
        old_inbound_tracks,
        outbound_tracks,
        mid_to_track_id,
        simulcast?
      ) do
    send_only_sdp_media = Enum.filter(sdp.media, &(:sendonly in &1.attributes))

    stream_id = Track.stream_id()

    {new_inbound_tracks, new_inbound_disabled_tracks} =
      Enum.map(
        send_only_sdp_media,
        &create_track_from_sdp_media(
          &1,
          stream_id,
          codecs_filter,
          enabled_extensions,
          mid_to_track_id,
          simulcast?
        )
      )
      |> get_new_tracks(old_inbound_tracks)
      |> split_by_disabled_tracks()

    {same_inbound_tracks, removed_inbound_tracks} =
      update_inbound_tracks_status(old_inbound_tracks, mid_to_track_id)

    old_inbound_tracks = removed_inbound_tracks ++ same_inbound_tracks

    recv_only_sdp_media_data = get_media_by_attribute(sdp, codecs_filter, :recvonly)
    outbound_tracks = get_outbound_tracks_updated(recv_only_sdp_media_data, outbound_tracks)

    {new_inbound_tracks, removed_inbound_tracks,
     new_inbound_tracks ++ new_inbound_disabled_tracks ++ old_inbound_tracks, outbound_tracks}
  end

  defp update_inbound_tracks_status(old_inbound_tracks, mid_to_track_id),
    do:
      Enum.split_with(old_inbound_tracks, fn old_track ->
        Map.has_key?(mid_to_track_id, old_track.mid) or old_track.status == :disabled
      end)
      |> then(fn {same_tracks, tracks_to_update} ->
        Enum.map(tracks_to_update, &%{&1 | status: :disabled})
        |> then(&{same_tracks, &1})
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

  defp get_new_tracks(inbound_tracks, old_inbound_tracks) do
    known_ids = Enum.map(old_inbound_tracks, fn track -> track.id end)
    Enum.filter(inbound_tracks, &(&1.id not in known_ids))
  end

  defp split_by_disabled_tracks(inbound_tracks) do
    Enum.split_with(inbound_tracks, fn %Track{status: status} -> status != :disabled end)
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
    extmaps = Media.get_attributes(sdp_media, :extmap)

    if new_rtp_fmtp_pairs === [] do
      raise "All payload types in SDP offer are unsupported"
    else
      %{
        rtp_fmtp_mappings: new_rtp_fmtp_pairs,
        mid: mid,
        media_type: media_type,
        disabled?: disabled?,
        extmaps: extmaps
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
      media_data
      |> Enum.filter(&(&1.media_type === type))
      |> Enum.sort_by(sort_mid)

    tracks = tracks |> Enum.filter(&(&1.type === type)) |> Enum.sort_by(sort_mid)

    Enum.zip(media_data, tracks)
    |> Map.new(fn {media, track} ->
      {track.id, update_mapping_and_mid_for_track(track, media)}
    end)
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

      extmaps =
        Enum.filter(mappings.extmaps, fn extmap ->
          Enum.any?(track.extmaps, &(&1.uri == extmap.uri))
        end)

      %{track | mid: mappings.mid, rtp_mapping: rtp, fmtp: fmtp, extmaps: extmaps}
    end
  end

  defp encoding_name_to_string(encoding_name) do
    case(encoding_name) do
      :VP8 -> "VP8"
      :H264 -> "H264"
      :OPUS -> "opus"
      x -> to_string(x)
    end
  end

  defp create_track_from_sdp_media(
         sdp_media,
         stream_id,
         codecs_filter,
         enabled_extensions,
         mid_to_track_id,
         simulcast?
       ) do
    media_type = sdp_media.type

    rids =
      sdp_media
      |> Media.get_attributes("rid")
      |> Enum.map(fn {_attr, rid} ->
        rid |> String.split(" ", parts: 2) |> hd()
      end)

    %{rtp_fmtp_mappings: [{rtp, fmtp} | _], mid: mid, disabled?: disabled} =
      get_mid_type_mappings_from_sdp_media(sdp_media, codecs_filter)

    # if simulcast was offered but we don't accept it, turn track off
    # this is not compliant with WebRTC standard as we should only
    # remove simulcast attributes and be prepared to receive one
    # encoding but in such a case browser changes SSRC after ICE restart
    # and we cannot handle this at the moment
    rids = if(rids == [], do: nil, else: rids)
    disabled = if rids != nil and simulcast? == false, do: true, else: disabled

    ssrc = Media.get_attribute(sdp_media, :ssrc)
    # this function is being called only for inbound media
    # therefore, if SSRC is `nil` `sdp_media` must represent simulcast track
    ssrc = if ssrc == nil, do: [], else: ssrc.id

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
      rids: rids,
      rtp_mapping: rtp,
      fmtp: fmtp,
      status: if(disabled, do: :disabled, else: :ready),
      extmaps: supported_extmaps
    ]

    Track.new(media_type, stream_id, opts)
  end

  @doc """
  Resolves RTP header extensions by creating mapping between extension name and extension data.
  """
  @spec resolve_rtp_header_extensions(
          Track.t(),
          [Membrane.RTP.Header.Extension.t()],
          [Membrane.WebRTC.Extension]
        ) :: %{(extension_name :: atom()) => extension_data :: binary()}
  def resolve_rtp_header_extensions(track, rtp_header_extensions, modules) do
    Map.new(rtp_header_extensions, fn extension ->
      extension_name =
        Enum.find(track.extmaps, &(&1.id == extension.identifier))
        |> then(&Extension.from_extmap(modules, &1))
        |> then(& &1.name)

      {extension_name, extension.data}
    end)
  end

  @doc """
  Check if this is simulcast ssrc

  Simulcast ssrc has format like this: `simulcast<mid>`
  """
  @spec simulcast_ssrc?(ssrc :: any()) :: boolean()
  def simulcast_ssrc?(ssrc), do: is_binary(ssrc) and String.starts_with?(ssrc, "simulcast")
end

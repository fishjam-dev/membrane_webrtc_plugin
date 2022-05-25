defmodule Membrane.WebRTC.SDP do
  @moduledoc false

  alias ExSDP.Attribute.{RTPMapping, MSID, SSRC, FMTP, Group}
  alias ExSDP.{ConnectionData, Media}
  alias Membrane.WebRTC.{Extension, Track, Utils}

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
      (inbound_tracks ++ outbound_tracks)
      |> Enum.map(& &1.mid)
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

  Function returns four-element tuple, which contains list of new active tracks, list of removed tracks, list of all inbound tracks
  and list of all outbound tracks.
  New disabled inbound tracks (new tracks but disabled after applying constraints) are in list of all inbound tracks.

  Function arguments:
  * sdp - SDP offer
  * constraints - track constraints e.g. extensions to use
  * old_inbound_tracks - list of old inbound tracks
  * outbound_tracks - list of outbound_tracks
  * mid_to_track_id - map of mid to track_id for all active inbound_tracks
  """
  @spec get_tracks(
          sdp :: ExSDP.t(),
          constraints :: Track.Constraints.t(),
          old_inbound_tracks :: [Track.t()],
          outbound_tracks :: [Track.t()],
          mid_to_track_id :: %{String.t() => Track.id()}
        ) ::
          {new_inbound_tracks :: [Track.t()], removed_inbound_tracks :: [Track.t()],
           inbound_tracks :: [Track.t()], outbound_tracks :: [Track.t()]}
  def get_tracks(sdp, constraints, old_inbound_tracks, outbound_tracks, mid_to_track_id) do
    if Enum.any?(sdp.media, fn mline -> Media.get_attribute(mline, :sendrecv) != nil end) do
      raise("Tracks with direction :sendrecv are not allowed. Offer: #{inspect(sdp)}")
    end

    {send_only_sdp_media, rest_sdp_media} =
      Enum.split_with(sdp.media, &(:sendonly in &1.attributes))

    {recv_only_sdp_media, _rest_sdp_media} =
      Enum.split_with(rest_sdp_media, &(:recvonly in &1.attributes))

    # TODO should stream_id be the same for all tracks?
    stream_id = Track.stream_id()

    # new_inbound_disabled_tracks are tracks that
    # peer wanted to send to us but we disabled them
    # after applying constraints
    {new_inbound_tracks, new_inbound_disabled_tracks} =
      send_only_sdp_media
      |> Enum.map(fn sdp_media ->
        {:mid, mid} = Media.get_attribute(sdp_media, :mid)
        track_id = mid_to_track_id[mid]
        Track.from_sdp_media(sdp_media, track_id, stream_id)
      end)
      |> get_new_tracks(old_inbound_tracks)
      |> Enum.map(&Track.set_constraints(&1, :inbound, constraints))
      |> split_by_disabled_tracks()

    {same_inbound_tracks, removed_inbound_tracks} =
      Enum.split_with(old_inbound_tracks, fn old_track ->
        Map.has_key?(mid_to_track_id, old_track.mid) or old_track.status == :disabled
      end)

    removed_inbound_tracks = Enum.map(removed_inbound_tracks, &%{&1 | status: :disabled})

    old_inbound_tracks = removed_inbound_tracks ++ same_inbound_tracks

    outbound_sdp_tracks = Enum.map(recv_only_sdp_media, &Track.from_sdp_media(&1))

    if length(outbound_sdp_tracks) > length(outbound_tracks) do
      raise("Received new outbound tracks in SDP offer which is not allowed.")
    end

    outbound_tracks = update_outbound_tracks(outbound_tracks, outbound_sdp_tracks)

    inbound_tracks = new_inbound_tracks ++ new_inbound_disabled_tracks ++ old_inbound_tracks
    {new_inbound_tracks, removed_inbound_tracks, inbound_tracks, outbound_tracks}
  end

  defp get_new_tracks(tracks, old_tracks) do
    old_track_ids = Enum.map(old_tracks, & &1.id)
    Enum.filter(tracks, &(&1.id not in old_track_ids))
  end

  defp split_by_disabled_tracks(inbound_tracks) do
    Enum.split_with(inbound_tracks, fn %Track{status: status} -> status != :disabled end)
  end

  defp update_outbound_tracks(outbound_tracks, outbound_sdp_tracks) do
    # this function updates outbound track fields according to the new SDP offer
    #
    # explanation: mid of outbound track can change between subsequent SDP offers and different
    # browsers can have different payload type for the same codec
    {audio_tracks, video_tracks} = Enum.split_with(outbound_tracks, &(&1.type == :audio))

    {audio_sdp_tracks, video_sdp_tracks} =
      Enum.split_with(outbound_sdp_tracks, &(&1.type == :audio))

    audio_tracks = do_update_outbound_tracks(audio_tracks, audio_sdp_tracks)
    video_tracks = do_update_outbound_tracks(video_tracks, video_sdp_tracks)

    audio_tracks ++ video_tracks
  end

  defp do_update_outbound_tracks(outbound_tracks, outbound_sdp_tracks) do
    sort_by_mid = &if &1.mid != nil, do: String.to_integer(&1.mid), else: nil

    outbound_tracks = Enum.sort_by(outbound_tracks, sort_by_mid)
    outbound_sdp_tracks = Enum.sort_by(outbound_sdp_tracks, sort_by_mid)

    outbound_tracks
    |> Enum.zip(outbound_sdp_tracks)
    |> Enum.map(fn {track, sdp_track} ->
      update_outbound_track(track, sdp_track)
    end)
  end

  defp update_outbound_track(track, sdp_track) do
    encoding_string = Utils.encoding_name_to_string(track.encoding)

    rtp_fmtp_pairs = Utils.pair_rtp_mappings_with_fmtp(sdp_track)

    selected_rtp_fmtp_pair =
      Enum.find(rtp_fmtp_pairs, fn {rtp, _fmtp} ->
        rtp.encoding == encoding_string
      end)

    if selected_rtp_fmtp_pair == nil do
      %{track | mid: sdp_track.mid, status: :disabled}
    else
      {rtp, fmtp} = selected_rtp_fmtp_pair

      extmaps =
        Enum.filter(sdp_track.extmaps, fn extmap ->
          Enum.any?(track.extmaps, &(&1.uri == extmap.uri))
        end)

      %Track{track | mid: sdp_track.mid, rtp_mapping: rtp, fmtp: fmtp, extmaps: extmaps}
    end
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

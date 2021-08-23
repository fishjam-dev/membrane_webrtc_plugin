defmodule Membrane.WebRTC.SDP do
  @moduledoc """
  Module containing helper functions for creating SPD offer.
  """

  alias ExSDP.Attribute.{RTPMapping, MSID, SSRC, FMTP, Group}
  alias ExSDP.{ConnectionData, Media}
  alias Membrane.WebRTC.Track

  @type fingerprint :: {ExSDP.Attribute.hash_function(), binary()}

  @doc """
  Creates Unified Plan SDP offer.

  The mandatory options are:
  - ice_ufrag - ICE username fragment
  - ice_pwd - ICE password
  - fingerprint - DTLS fingerprint
  - inbound_tracks - list of inbound tracks
  - outbound_tracks - list of outbound tracks

  Additionally accepts audio_codecs and video_codecs options,
  that should contain lists of SDP attributes for desired codecs,
  for example:

      video_codecs: [
        %RTPMapping{payload_type: 98, encoding: "VP9", clock_rate: 90_000}
      ]

  By default both lists are empty and default audio and video codecs get appended including
  OPUS for audio, H264 and VP8 for video.

  To disable all or enable just one specific codec type use `use_default_codecs` option.
  To disable default codecs pass an empty list. To enable only either audio or video, pass a list
  with a single atom `[:audio]` or `[:video]`.
  """
  @spec create_offer(
          ice_ufrag: String.t(),
          ice_pwd: String.t(),
          fingerprint: fingerprint(),
          audio_codecs: [ExSDP.Attribute.t()],
          video_codecs: [ExSDP.Attribute.t()],
          inbound_tracks: [Track.t()],
          outbound_tracks: [Track.t()],
          use_default_codecs: [:audio | :video],
          mappings: %{}
        ) :: ExSDP.t()
  def create_offer(opts) do
    mappings = Keyword.get(opts, :mappings, %{})

    config = %{
      ice_ufrag: Keyword.fetch!(opts, :ice_ufrag),
      ice_pwd: Keyword.fetch!(opts, :ice_pwd),
      fingerprint: Keyword.fetch!(opts, :fingerprint),
      codecs: %{
        audio: Keyword.get(opts, :audio_codecs, []),
        video: Keyword.get(opts, :video_codecs, [])
      },
      fmt_mappings: mappings
    }

    # TODO verify if sorting tracks this way allows for adding inbound tracks in updated offer
    inbound_tracks = Keyword.fetch!(opts, :inbound_tracks) |> Enum.sort_by(& &1.timestamp)
    outbound_tracks = Keyword.fetch!(opts, :outbound_tracks) |> Enum.sort_by(& &1.timestamp)

    mids =
      Enum.map(inbound_tracks ++ outbound_tracks, &Map.get(mappings, &1.id))
      |> Enum.filter(&(&1 !== nil))
      |> Enum.map(& &1.mid)

    attributes = [
      %Group{semantics: "BUNDLE", mids: mids},
      "extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level vad=on"
    ]

    %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
    |> ExSDP.add_attributes(attributes)
    |> add_tracks(inbound_tracks, :recvonly, config)
    |> add_tracks(outbound_tracks, :sendonly, config)
  end

  @spec create_answer(
          ice_ufrag: String.t(),
          ice_pwd: String.t(),
          fingerprint: fingerprint(),
          audio_codecs: [ExSDP.Attribute.t()],
          video_codecs: [ExSDP.Attribute.t()],
          inbound_tracks: [Track.t()],
          outbound_tracks: [Track.t()],
          mappings: %{}
        ) :: ExSDP.t()
  def create_answer(opts) do
    mappings = Keyword.fetch!(opts, :mappings)

    inbound_tracks = Keyword.fetch!(opts, :inbound_tracks) |> Enum.sort_by(& &1.timestamp)
    outbound_tracks = Keyword.fetch!(opts, :outbound_tracks) |> Enum.sort_by(& &1.timestamp)
    mids = Enum.map(inbound_tracks ++ outbound_tracks, &Map.get(mappings, &1.id).mid)

    outbound_tracks =
      Enum.map(outbound_tracks, &{Map.get(mappings, &1.id), &1})
      |> Enum.sort_by(fn {mapping, _track} -> Integer.parse(mapping.mid) end)
      |> Enum.map(fn {_mapping, track} -> track end)

    config = %{
      ice_ufrag: Keyword.fetch!(opts, :ice_ufrag),
      ice_pwd: Keyword.fetch!(opts, :ice_pwd),
      fingerprint: Keyword.fetch!(opts, :fingerprint),
      codecs: %{
        audio: Keyword.get(opts, :audio_codecs, []),
        video: Keyword.get(opts, :video_codecs, [])
      },
      fmt_mappings: mappings
    }

    attributes = [
      %Group{semantics: "BUNDLE", mids: mids}
    ]

    %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
    |> ExSDP.add_attributes(attributes)
    |> add_tracks(inbound_tracks, :recvonly, config)
    |> add_tracks(outbound_tracks, :sendonly, config)
  end

  defp encoding_name_to_string(encoding_name) do
    case(encoding_name) do
      :VP8 -> "VP8"
      :H264 -> "H264"
      :OPUS -> "opus"
      x -> to_string(x)
    end
  end

  defp track_data_to_rtp_mapping(track_data),
    do: %RTPMapping{
      clock_rate: track_data.clock_rate,
      encoding: encoding_name_to_string(track_data.encoding_name),
      payload_type: track_data.payload_type,
      params: track_data.params
    }

  defp add_tracks(sdp, tracks, direction, config) do
    ExSDP.add_media(sdp, Enum.map(tracks, &create_sdp_media(&1, direction, config)))
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

    track_data =
      config
      |> Map.get(:fmt_mappings, %{})
      |> Map.get(track.id, %{})

    payload_type =
      if Map.has_key?(track_data, :payload_type),
        do: [track_data.payload_type],
        else: get_payload_types(codecs)

    rtp_mapping = if track_data != %{}, do: track_data_to_rtp_mapping(track_data), else: %{}

    %Media{
      Media.new(track.type, 9, "UDP/TLS/RTP/SAVPF", payload_type)
      | connection_data: [%ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> Media.add_attributes([
      if(track.enabled?, do: direction, else: :inactive),
      {:ice_ufrag, config.ice_ufrag},
      {:ice_pwd, config.ice_pwd},
      {:ice_options, "trickle"},
      {:fingerprint, config.fingerprint},
      {:setup, if(direction == :recvonly, do: :passive, else: :active)},
      {:mid, if(track_data !== %{}, do: track_data.mid, else: "")},
      MSID.new(track.stream_id),
      :rtcp_mux
    ])
    |> Media.add_attributes(get_rtp_mapping(rtp_mapping, codecs))
    |> add_standard_extensions()
    |> add_extensions(track.type, payload_type)
    |> add_ssrc(track)
  end

  defp get_fmtp_for_h264(pt),
    do: %FMTP{
      pt: pt,
      level_asymmetry_allowed: true,
      packetization_mode: 1,
      profile_level_id: 0x42E01F
    }

  defp get_rtp_mapping(rtp_mapping, codecs) do
    cond do
      rtp_mapping === %{} ->
        codecs

      rtp_mapping.encoding === "H264" ->
        [rtp_mapping, get_fmtp_for_h264(rtp_mapping.payload_type)]

      true ->
        [rtp_mapping]
    end
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
      x -> raise "Not supported now #{x}"
    end
  end

  @spec get_mappings_with_mids(any) :: any
  def get_mappings_with_mids(sdp),
    do: Enum.map(sdp.media, &get_mid_type_mappings_from_sdp_media(&1))

  @spec get_proper_mapping_for_track(
          any,
          atom | %{:mappings => any, :media_type => any, :mid => any, optional(any) => any}
        ) :: %{
          clock_rate: any,
          encoding_name: :H264 | :OPUS | :VP8,
          mid: any,
          params: any,
          payload_type: any,
          type: any
        }
  def get_proper_mapping_for_track(track, mappings) do
    encoding_string = encoding_name_to_string(track.encoding)
    mapping = Enum.find(mappings.mappings, &(&1.encoding === encoding_string))

    mapping_with_mid_and_type(mappings.mid, mappings.media_type, mapping)
  end

  defp mapping_with_mid_and_type(mid, media_type, mapping),
    do: %{
      encoding_name: encoding_to_atom(mapping.encoding),
      clock_rate: mapping.clock_rate,
      payload_type: mapping.payload_type,
      params: mapping.params,
      mid: mid,
      type: media_type
    }

  defp filter_mappings(rtp_fmtp_pair) do
    {rtp, fmtp} = rtp_fmtp_pair

    case rtp.encoding do
      "opus" -> true
      "VP8" -> true
      "H264" -> fmtp.profile_level_id === 0x42E01F
      _unsupported_codec -> false
    end
  end

  defp get_mid_type_mappings_from_sdp_media(sdp_media) do
    media_type = sdp_media.type
    {:mid, mid} = Media.get_attribute(sdp_media, :mid)
    rtp_mappings = for %RTPMapping{} = rtp_mapping <- sdp_media.attributes, do: rtp_mapping
    fmtp_mappings = for %FMTP{} = fmtp_mapping <- sdp_media.attributes, do: fmtp_mapping

    pt_to_fmtp = Map.new(fmtp_mappings, &{&1.pt, &1})

    rtp_fmtp_pairs = Enum.map(rtp_mappings, &{&1, Map.get(pt_to_fmtp, &1.payload_type)})

    rtp_mappings =
      rtp_fmtp_pairs |> Enum.filter(&filter_mappings(&1)) |> Enum.map(fn {rtp, _fmtp} -> rtp end)

    %{mappings: rtp_mappings, mid: mid, media_type: media_type}
  end

  defp get_mapping_from_sdp_media(sdp_media) do
    %{mappings: [mapping | _], mid: mid, media_type: media_type} =
      get_mid_type_mappings_from_sdp_media(sdp_media)

    mapping_with_mid_and_type(mid, media_type, mapping)
  end

  @spec create_track_from_sdp_media(ExSDP.Media.t(), binary) :: %{mapping: any, track: any}
  def create_track_from_sdp_media(sdp_media, stream_id) do
    media_type = sdp_media.type

    ssrc = Enum.uniq(for %SSRC{} = ssrc <- sdp_media.attributes, do: ssrc.id)

    mapping = get_mapping_from_sdp_media(sdp_media)

    opts = [ssrc: List.first(ssrc), encoding: mapping.encoding_name]

    track = Track.new(media_type, stream_id, opts)

    %{track: track, mapping: Map.put(mapping, :track_id, track.id)}
  end

  @spec filter_sdp_media(ExSDP.t(), any) :: [Media.t()]
  def filter_sdp_media(sdp, filter_function), do: Enum.filter(sdp.media, &filter_function.(&1))
end

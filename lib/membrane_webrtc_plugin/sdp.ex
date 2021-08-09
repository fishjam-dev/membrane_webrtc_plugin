defmodule Membrane.WebRTC.SDP do
  @moduledoc """
  Module containing helper functions for creating SPD offer.
  """

  alias ExSDP.Attribute.{RTPMapping, MSID, SSRC, Group}
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
      |> Enum.sort_by(&elem(&1, 0).mid)
      |> Enum.map(&elem(&1, 1))

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

  defp track_data_to_rtp_mapping(track_data),
    do: %RTPMapping{
      clock_rate: track_data.clock_rate,
      encoding: track_data.encoding_name |> Atom.to_string() |> String.downcase(),
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
    |> Media.add_attributes(if rtp_mapping !== %{}, do: [rtp_mapping], else: codecs)
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
    do: Media.add_attribute(media, %SSRC{id: track.ssrc, attribute: "cname", value: track.name})

  defp get_payload_types(codecs) do
    Enum.flat_map(codecs, fn
      %RTPMapping{payload_type: pt} -> [pt]
      _attr -> []
    end)
  end

  defp drop_while(list, drop?) do
    if list !== [] do
      [head | tail] = list
      if drop?.(head), do: drop_while(tail, drop?), else: list
    else
      []
    end
  end

  @line_ending "\r\n"

  @spec remove_sdp_header_data(binary) :: binary
  def remove_sdp_header_data(sdp_offer) do
    String.split(sdp_offer, @line_ending)
    |> drop_while(&(!String.starts_with?(&1, "m=")))
    |> Enum.join(@line_ending)
  end

  defp encoding_to_atom(encoding_name) do
    case encoding_name do
      "opus" -> :OPUS
      "VP8" -> :VP8
      "H264" -> :H264
      x -> raise "Not supported now #{x}"
    end
  end

  @spec get_mid_to_mapping(any) :: any
  def get_mid_to_mapping(sdp) do
    mappings = Enum.map(sdp.media, &get_mapping_from_sdp_media(&1))
    Enum.reduce(mappings, %{}, &Map.merge(&2, %{&1.mid => &1}))
  end

  defp get_mapping_from_sdp_media(sdp_media) do
    media_type = sdp_media.type
    [mapping | _] = for %RTPMapping{} = rtp_mapping <- sdp_media.attributes, do: rtp_mapping
    {:mid, mid} = Media.get_attribute(sdp_media, :mid)

    %{
      encoding_name: encoding_to_atom(mapping.encoding),
      clock_rate: mapping.clock_rate,
      payload_type: mapping.payload_type,
      params: mapping.params,
      mid: mid,
      type: media_type
    }
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

  @spec get_type_and_ssrc(Media.t()) :: [type: any, ssrc: any]
  def get_type_and_ssrc(sdp_media) do
    media_type = sdp_media.type
    ssrc = Enum.uniq(for %SSRC{} = ssrc <- sdp_media.attributes, do: ssrc.id)
    [type: media_type, ssrc: ssrc]
  end

  @spec add_ssrc_to_media_from_tracks(Media.t() | [Media.t()], any, any, [any]) :: any
  def add_ssrc_to_media_from_tracks([media | medias], audios, videos, acc) do
    case media.type do
      :audio ->
        [audio | audios] = audios
        media = add_ssrc(media, audio)
        add_ssrc_to_media_from_tracks(medias, audios, videos, acc ++ [media])

      :video ->
        [video | videos] = videos
        media = add_ssrc(media, video)
        add_ssrc_to_media_from_tracks(medias, audios, videos, acc ++ [media])
    end
  end

  @spec add_ssrc_to_media_from_tracks([], any, any, [any]) :: any
  def add_ssrc_to_media_from_tracks([], _audio, _video, acc), do: acc
end

defmodule Membrane.WebRTC.SDP do
  @moduledoc """
  Module containing helper functions for creating SPD offer.
  """

  alias ExSDP.Attribute.{RTPMapping, MSID, FMTP, SSRC, Group}
  alias ExSDP.{ConnectionData, Media}
  alias Membrane.RTP.PayloadFormat
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
          use_default_codecs: [:audio | :video]
        ) :: ExSDP.t()
  def create_offer(opts) do
    fmt_mappings = Keyword.get(opts, :fmt_mappings, %{})

    use_default_codecs = Keyword.get(opts, :use_default_codecs, true)

    config = %{
      ice_ufrag: Keyword.fetch!(opts, :ice_ufrag),
      ice_pwd: Keyword.fetch!(opts, :ice_pwd),
      fingerprint: Keyword.fetch!(opts, :fingerprint),
      codecs: %{
        audio:
          Keyword.get(opts, :audio_codecs, []) ++
            if(:audio in use_default_codecs, do: get_default_audio_codecs(fmt_mappings), else: []),
        video:
          Keyword.get(opts, :video_codecs, []) ++
            if(:video in use_default_codecs, do: get_default_video_codecs(fmt_mappings), else: [])
      }
    }

    # TODO verify if sorting tracks this way allows for adding inbound tracks in updated offer
    inbound_tracks = Keyword.fetch!(opts, :inbound_tracks) |> Enum.sort_by(& &1.timestamp)
    outbound_tracks = Keyword.fetch!(opts, :outbound_tracks) |> Enum.sort_by(& &1.timestamp)
    mids = Enum.map(inbound_tracks ++ outbound_tracks, & &1.id)

    attributes = [
      %Group{semantics: "BUNDLE", mids: mids},
      "extmap:6 urn:ietf:params:rtp-hdrext:ssrc-audio-level vad=on"
    ]

    %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
    |> ExSDP.add_attributes(attributes)
    |> add_tracks(inbound_tracks, :recvonly, config)
    |> add_tracks(outbound_tracks, :sendonly, config)
  end

  defp add_tracks(sdp, tracks, direction, config) do
    ExSDP.add_media(sdp, Enum.map(tracks, &create_sdp_media(&1, direction, config)))
  end

  defp create_sdp_media(track, direction, config) do
    codecs = config.codecs[track.type]
    payload_types = get_payload_types(codecs)

    %Media{
      Media.new(track.type, 9, "UDP/TLS/RTP/SAVPF", payload_types)
      | connection_data: [%ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> Media.add_attributes([
      if(track.enabled?, do: direction, else: :inactive),
      {:ice_ufrag, config.ice_ufrag},
      {:ice_pwd, config.ice_pwd},
      {:ice_options, "trickle"},
      {:fingerprint, config.fingerprint},
      {:setup, :actpass},
      {:mid, track.id},
      MSID.new(track.stream_id),
      :rtcp_mux
    ])
    |> Media.add_attributes(codecs)
    |> add_extensions(track.type, payload_types)
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

  defp get_default_audio_codecs(fmt_mappings), do: get_opus(fmt_mappings)

  defp get_default_video_codecs(fmt_mappings),
    do: get_vp8(fmt_mappings) ++ get_h264(fmt_mappings)

  defp get_opus(fmt_mappings) do
    %PayloadFormat{payload_type: pt} = PayloadFormat.get(:OPUS)
    %{encoding_name: en, clock_rate: cr} = PayloadFormat.get_payload_type_mapping(pt)
    pt = Map.get(fmt_mappings, :OPUS, pt)
    rtp_mapping = %RTPMapping{clock_rate: cr, encoding: "#{en}", params: 2, payload_type: pt}
    fmtp = %FMTP{pt: pt, useinbandfec: true}
    [rtp_mapping, fmtp]
  end

  defp get_vp8(fmt_mappings) do
    %PayloadFormat{payload_type: pt} = PayloadFormat.get(:VP8)
    %{encoding_name: en, clock_rate: cr} = PayloadFormat.get_payload_type_mapping(pt)
    pt = Map.get(fmt_mappings, :VP8, pt)
    rtp_mapping = %RTPMapping{clock_rate: cr, encoding: "#{en}", payload_type: pt}
    [rtp_mapping]
  end

  defp get_h264(fmt_mappings) do
    %PayloadFormat{payload_type: pt} = PayloadFormat.get(:H264)
    %{encoding_name: en, clock_rate: cr} = PayloadFormat.get_payload_type_mapping(pt)
    pt = Map.get(fmt_mappings, :H264, pt)
    rtp_mapping = %RTPMapping{clock_rate: cr, encoding: "#{en}", payload_type: pt}

    fmtp = %FMTP{
      pt: pt,
      level_asymmetry_allowed: true,
      packetization_mode: 1,
      profile_level_id: 0x42E01F
    }

    [rtp_mapping, fmtp]
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

  def remove_sdp_header_data(sdp_offer) do
    String.split(sdp_offer, @line_ending)
    |> drop_while(&(!String.starts_with?(&1, "m=")))
    |> Enum.join(@line_ending)
  end

  defp media_setup_type(sdp_media,inbound_ssrcs) do
    [ssrc | _] = for %SSRC{id: id} <- sdp_media.attributes, do: id
    if ssrc not in inbound_ssrcs, do: :active, else: :passive
  end

  defp replace_media_for_answer(sdp_media, opts) do
    setup = media_setup_type(sdp_media,opts.ssrcs)
    attrs =
      for attr <- sdp_media.attributes do
        case attr do
          {:ice_ufrag, _} -> {:ice_ufrag, opts.ice.ufrag}
          {:ice_pwd, _} -> {:ice_pwd, opts.ice.pwd}
          {:fingerprint, _} -> {:fingerprint, opts.fingerprint}
          :sendonly -> :recvonly
          :recvonly -> :sendonly
          {:setup, :actpass} -> {:setup, setup}
          {"extmap", _} -> nil
          {"rtcp-fb", _} -> nil
          # %SSRC{id: _, attribute: "cname", value: _} = val -> val
          %RTPMapping{encoding: "telephone-event"} -> nil
          %RTPMapping{encoding: "ulpfec"} -> nil
          %RTPMapping{encoding: "rtx"} -> nil
          %RTPMapping{encoding: "red"} -> nil
          # %RTPMapping{encoding: "H264"} -> nil
          # %SSRC{} = _ -> nil
          %FMTP{} = _ -> nil
          x -> x
        end
      end

    attrs = for attr <- attrs, attr !== nil, do: attr
    %{sdp_media | attributes: attrs}
  end

  @spec prepare_answer_from_offer(%{:media => any, optional(any) => any}, any) :: %{
          :media => list,
          optional(any) => any
        }
  def prepare_answer_from_offer(sdp, opts) do
    sdp = %{sdp | origin: ExSDP.Origin.new()}
    %{sdp | media: Enum.map(sdp.media, &replace_media_for_answer(&1, opts))}
  end

  defp encoding_to_atom(encoding_name) do
    case encoding_name do
      "opus" -> :OPUS
      "VP8" -> :VP8
      x -> raise "Not supported now #{x}"
    end
  end

  defp register_track_in_payload_formatter(sdp_media) do
    [mapping | _] = for %RTPMapping{} = rtp_mapping <- sdp_media.attributes, do: rtp_mapping

    %{
      encoding_name: encoding_to_atom(mapping.encoding),
      clock_rate: mapping.clock_rate,
      payload_type: mapping.payload_type
    }
  end

  def create_track_from_sdp_media(sdp_media, stream_id) do
    media_type = sdp_media.type

    ssrc = Enum.uniq(for %SSRC{} = ssrc <- sdp_media.attributes, do: ssrc.id)

    mapping = register_track_in_payload_formatter(sdp_media)

    opts = [ssrc: ssrc, encoding: mapping.encoding_name]

    track = Track.new(media_type, stream_id, opts)

    %{track: track, mapping: Map.put(mapping, :track_id, track.id)}
  end

  def filter_sdp_media(sdp, filter_function), do: Enum.filter(sdp.media, &filter_function.(&1))

  def get_type_and_ssrc(sdp_media) do
    media_type = sdp_media.type
    ssrc = Enum.uniq(for %SSRC{} = ssrc <- sdp_media.attributes, do: ssrc.id)
    [type: media_type, ssrc: ssrc]
  end

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

  def add_ssrc_to_media_from_tracks([], _audio, _video, acc), do: acc

end

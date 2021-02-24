defmodule Membrane.WebRTC.SDP do
  @moduledoc """
  Module containing helper functions for creating SPD offer.
  """

  alias ExSDP.Attribute.{RTPMapping, MSID, FMTP, SSRC}
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

  Additionally accepts audio_codecs and video_codecs options,
  that should contain lists of SDP attributes for desired codecs.
  Both lists are empty by default, while Opus and H264 codecs'
  attributes are appended to audio and video, respectively.
  """
  @spec create_offer(
          ice_ufrag: String.t(),
          ice_pwd: String.t(),
          fingerprint: fingerprint(),
          audio_codecs: [ExSDP.Attribute.t()],
          video_codecs: [ExSDP.Attribute.t()]
        ) :: ExSDP.t()
  def create_offer(opts) do
    fmt_mappings = Keyword.get(opts, :fmt_mappings, %{})

    config = %{
      ice_ufrag: Keyword.fetch!(opts, :ice_ufrag),
      ice_pwd: Keyword.fetch!(opts, :ice_pwd),
      fingerprint: Keyword.fetch!(opts, :fingerprint),
      codecs: %{
        audio: Keyword.get(opts, :audio_codecs, []) ++ get_opus(fmt_mappings),
        video: Keyword.get(opts, :video_codecs, []) ++ get_h264(fmt_mappings)
      }
    }

    # TODO verify if sorting tracks this way allows for adding inbound tracks in updated offer
    inbound_tracks = Keyword.fetch!(opts, :inbound_tracks) |> Enum.sort_by(& &1.timestamp)
    outbound_tracks = Keyword.fetch!(opts, :outbound_tracks) |> Enum.sort_by(& &1.timestamp)
    bundle_group = Enum.map(inbound_tracks ++ outbound_tracks, & &1.id)

    %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
    |> ExSDP.add_attribute({:group, {:BUNDLE, bundle_group}})
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

  defp get_opus(fmt_mappings) do
    %PayloadFormat{payload_type: pt} = PayloadFormat.get(:OPUS)
    %{encoding_name: en, clock_rate: cr} = PayloadFormat.get_payload_type_mapping(pt)
    pt = Map.get(fmt_mappings, :OPUS, pt)
    rtp_mapping = %RTPMapping{clock_rate: cr, encoding: "#{en}", params: 2, payload_type: pt}
    fmtp = %FMTP{pt: pt, useinbandfec: true}
    [rtp_mapping, fmtp]
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
end

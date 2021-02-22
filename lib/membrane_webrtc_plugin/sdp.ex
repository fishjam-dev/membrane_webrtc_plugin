defmodule Membrane.WebRTC.SDP do
  @moduledoc """
  Module containing helper functions for creating SPD offer.
  """

  alias ExSDP.Attribute.{RTPMapping, Msid, Fmtp, Ssrc}
  alias ExSDP.{ConnectionData, Media}
  alias Membrane.RTP.PayloadFormat
  alias Membrane.WebRTC.Track

  @type fingerprint :: {ExSDP.Attribute.hash_function(), binary()}

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

    inbound_tracks = Keyword.fetch!(opts, :inbound_tracks)
    outbound_tracks = Keyword.fetch!(opts, :outbound_tracks)

    tracks_data =
      get_tracks_data(inbound_tracks, :recvonly) ++
        get_tracks_data(outbound_tracks, :sendonly)

    bundle_group = Enum.map(tracks_data, & &1.track.id)

    %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
    |> ExSDP.add_attribute({:group, {:BUNDLE, bundle_group}})
    |> add_tracks(tracks_data, config)
  end

  defp get_tracks_data(tracks, direction), do: Enum.map(tracks, &%{track: &1, direction: direction})

  defp add_tracks(sdp, tracks_data, config) do
    tracks_data
    |> Enum.sort_by(& &1.track.timestamp)
    |> Enum.reduce(sdp, fn track_data, sdp ->
      ExSDP.add_media(sdp, create_sdp_media(track_data, config))
    end)
  end

  defp create_sdp_media(%{track: track, direction: direction}, config) do
    codecs = config.codecs[track.type]
    payload_types = get_payload_types(codecs)

    %Media{
      Media.new(track.type, 9, "UDP/TLS/RTP/SAVPF", payload_types)
      | connection_data: %ConnectionData{address: {0, 0, 0, 0}}
    }
    |> Media.add_attribute(if track.enabled?, do: direction, else: :recvonly)
    |> Media.add_attribute({:ice_ufrag, config.ice_ufrag})
    |> Media.add_attribute({:ice_pwd, config.ice_pwd})
    |> Media.add_attribute({:ice_options, "trickle"})
    |> Media.add_attribute({:fingerprint, config.fingerprint})
    |> Media.add_attribute({:setup, :actpass})
    |> Media.add_attribute({:mid, track.id})
    |> Media.add_attribute(Msid.new(track.stream_id))
    |> Media.add_attribute(:rtcp_mux)
    |> add_codecs(codecs)
    |> add_extensions(track.type, payload_types)
    |> add_ssrc(track)
  end

  defp add_codecs(media, codecs) do
    Enum.reduce(codecs, media, fn attr, media -> Media.add_attribute(media, attr) end)
  end

  defp add_extensions(media, :audio, _pt), do: media

  defp add_extensions(media, :video, pt) do
    Enum.reduce(pt, media, fn pt, media ->
      Media.add_attribute(media, "rtcp-fb:#{pt} ccm fir")
    end)
    |> Media.add_attribute(:rtcp_rsize)
  end

  defp add_ssrc(media, %Track{ssrc: nil}), do: media

  defp add_ssrc(media, track),
    do: Media.add_attribute(media, %Ssrc{id: track.ssrc, attribute: "cname", value: track.name})

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
    fmtp = %Fmtp{pt: pt, useinbandfec: true}
    [rtp_mapping, fmtp]
  end

  defp get_h264(fmt_mappings) do
    %PayloadFormat{payload_type: pt} = PayloadFormat.get(:H264)
    %{encoding_name: en, clock_rate: cr} = PayloadFormat.get_payload_type_mapping(pt)
    pt = Map.get(fmt_mappings, :H264, pt)
    rtp_mapping = %RTPMapping{clock_rate: cr, encoding: "#{en}", payload_type: pt}

    fmtp = %Fmtp{
      pt: pt,
      level_asymmetry_allowed: true,
      packetization_mode: 1,
      profile_level_id: 0x42E01F
    }

    [rtp_mapping, fmtp]
  end
end

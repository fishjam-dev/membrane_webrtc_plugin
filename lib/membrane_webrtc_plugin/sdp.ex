defmodule Membrane.WebRTC.SDP do
  @moduledoc """
  Module containing helper functions for creating SPD offer.
  """

  alias ExSDP.{
    ConnectionData,
    Media
  }

  alias ExSDP.Attribute.{RTPMapping, Msid, Fmtp, Ssrc}
  alias Membrane.RTP.PayloadFormat

  defmodule Opts do
    @moduledoc """
    Module representing options that can be passed to `Membrane.WebRTC.SDP.create_offer/4`
    """

    @typedoc """
    Type describing custom ssrcs.
    """
    @type ssrcs :: %{audio: [], video: []}

    @typedoc """
    Type describing custom codecs.

    `encoding_name` - name of codec e.g. `:OPUS`, `:VP9`
    `pt` - payload type
    """
    @type codecs :: {encoding_name :: atom(), RTPMapping.t() | {RTPMapping.t(), Fmtp.t()}}

    @typedoc """
    Options that can be used to customize SDP.

    * `audio` and `video` indicates presence of audio and video streams. Both can't be set to
    `false` at the same time.
    * `peers` is the number of peers. E.g. setting `peers` to 2, `audio` and `video` to `true` will
    mean we have 4 streams - 2 audio and 2 video.
    * `ssrcs` are custom ssrcs. They should be specified for all streams or none. Applied in the
    order in which they were passed. E.g. passing `%{audio: [1, 2]}` will set ssrc of the first
    audio stream to 1 and ssrc of the second audio stream to 2.
    * `fmt_mappings` can be used to override payload types for default codecs i.e. OPUS and H264.
    * `audio_codecs` and `video_codecs` are custom codecs and they are added to the beginning of
    codec list which means they have priority over the default ones. There is no possibility to
    remove default codecs. You can add multiple codecs with the same encoding name (including
    encoding names of default codecs).
    """
    @type t :: %__MODULE__{
            audio: bool(),
            video: bool(),
            peers: pos_integer(),
            ssrcs: ssrcs(),
            fmt_mappings: %{OPUS: pos_integer(), H264: pos_integer()},
            audio_codecs: codecs(),
            video_codecs: codecs()
          }
    defstruct audio: true,
              video: true,
              peers: 1,
              ssrcs: nil,
              fmt_mappings: %{},
              audio_codecs: [],
              video_codecs: []
  end

  defmodule Config do
    @moduledoc false
    defstruct [
      :ice_ufrag,
      :ice_pwd,
      :fingerprint,
      audio: true,
      video: true,
      peers: 1,
      ssrcs: %{},
      audio_codecs: [],
      video_codecs: [],
      audio_cnt: 1,
      video_cnt: 1
    ]
  end

  @type fingerprint :: {ExSDP.Attribute.hash_function(), binary()}

  @doc """
  Creates SDP offer.

  By default there will be one peer, streaming both audio and video using H264 and OPUS.
  To set custom codecs (or custom parameters for default codecs), ssrcs, number of peers or
  turning off audio or video please refer to `Membrane.WebRTC.SDP.Opts`.
  """
  @spec create_offer(
          ice_ufrag :: binary(),
          ice_pwd :: binary(),
          fingerprint :: fingerprint(),
          opts :: Opts.t()
        ) :: ExSDP.t()
  def create_offer(ice_ufrag, ice_pwd, fingerprint, opts \\ %Opts{}) do
    do_create_offer(ice_ufrag, ice_pwd, fingerprint, opts)
  end

  defp do_create_offer(ice_ufrag, ice_pwd, fingerprint, opts) do
    config = parse_opts(ice_ufrag, ice_pwd, fingerprint, opts)
    bundle_group = for id <- 0..(config.audio_cnt + config.video_cnt - 1), do: "#{id}"
    timing = %ExSDP.Timing{start_time: 0, stop_time: 0}

    %ExSDP{ExSDP.new() | timing: timing}
    |> ExSDP.add_attribute({:group, {:BUNDLE, bundle_group}})
    |> add_media(config)
  end

  defp parse_opts(ice_ufrag, ice_pwd, fingerprint, opts) do
    if !opts.audio and !opts.video, do: raise("Either video or audio has to be set")
    if opts.peers < 1, do: raise("Number of peers has to be at least 1")

    audio_codecs = opts.audio_codecs ++ [{:OPUS, get_opus(opts.fmt_mappings)}]
    video_codecs = opts.video_codecs ++ [{:H264, get_h264(opts.fmt_mappings)}]

    audio_cnt = if opts.audio, do: opts.peers, else: 0
    video_cnt = if opts.video, do: opts.peers, else: 0
    ssrcs = opts.ssrcs || generate_ssrcs(audio_cnt, video_cnt)

    %Config{
      ice_pwd: ice_pwd,
      ice_ufrag: ice_ufrag,
      fingerprint: fingerprint,
      audio: opts.audio,
      video: opts.video,
      peers: opts.peers,
      ssrcs: ssrcs,
      audio_codecs: audio_codecs,
      video_codecs: video_codecs,
      audio_cnt: audio_cnt,
      video_cnt: video_cnt
    }
  end

  defp add_media(sdp, config) do
    {sdp, _next_mid} =
      0..(config.peers - 1)
      |> Enum.reduce({sdp, 0}, fn peer, {sdp, next_mid} ->
        msid_id = UUID.uuid4()
        {sdp, next_mid} = add_audio_media(sdp, peer, next_mid, msid_id, config)
        add_video_media(sdp, peer, next_mid, msid_id, config)
      end)

    sdp
  end

  defp add_audio_media(sdp, _peer, mid, _msid_id, %Config{audio: false}), do: {sdp, mid}

  defp add_audio_media(sdp, peer, mid, msid_id, config) do
    ssrc = Enum.at(config.ssrcs.audio, peer)
    media = get_audio_media(mid, msid_id, ssrc, config)
    sdp = ExSDP.add_media(sdp, media)
    {sdp, mid + 1}
  end

  defp add_video_media(sdp, _peer, mid, _msid_id, %Config{video: false}), do: {sdp, mid}

  defp add_video_media(sdp, peer, mid, msid_id, config) do
    ssrc = Enum.at(config.ssrcs.video, peer)
    media = get_video_media(mid, msid_id, ssrc, config)
    sdp = ExSDP.add_media(sdp, media)
    {sdp, mid + 1}
  end

  defp get_audio_media(mid, msid_id, ssrc, config) do
    pt = get_payload_types(config.audio_codecs)
    connection_data = %ConnectionData{address: {0, 0, 0, 0}}
    ssrc = %Ssrc{id: ssrc, attribute: "cname", value: "media" <> "#{mid}"}

    %Media{Media.new(:audio, 9, "UDP/TLS/RTP/SAVPF", pt) | connection_data: connection_data}
    |> Media.add_attribute(:sendrecv)
    |> Media.add_attribute({:ice_ufrag, config.ice_ufrag})
    |> Media.add_attribute({:ice_pwd, config.ice_pwd})
    |> Media.add_attribute({:ice_options, "trickle"})
    |> Media.add_attribute({:fingerprint, config.fingerprint})
    |> Media.add_attribute({:setup, :actpass})
    |> Media.add_attribute({:mid, "#{mid}"})
    |> Media.add_attribute(Msid.new(msid_id))
    |> Media.add_attribute(:rtcp_mux)
    |> add_codecs(config.audio_codecs)
    |> Media.add_attribute(ssrc)
  end

  defp get_video_media(mid, msid_id, ssrc, config) do
    pt = get_payload_types(config.video_codecs)
    connection_data = %ExSDP.ConnectionData{address: {0, 0, 0, 0}}
    ssrc = %Ssrc{id: ssrc, attribute: "cname", value: "media" <> "#{mid}"}

    %Media{Media.new(:video, 9, "UDP/TLS/RTP/SAVPF", pt) | connection_data: connection_data}
    |> Media.add_attribute({:ice_ufrag, config.ice_ufrag})
    |> Media.add_attribute({:ice_pwd, config.ice_pwd})
    |> Media.add_attribute({:ice_options, "trickle"})
    |> Media.add_attribute({:fingerprint, config.fingerprint})
    |> Media.add_attribute({:setup, :actpass})
    |> Media.add_attribute({:mid, "#{mid}"})
    |> Media.add_attribute(Msid.new(msid_id))
    |> Media.add_attribute(:rtcp_mux)
    |> Media.add_attribute(:rtcp_rsize)
    |> add_codecs(config.video_codecs)
    |> Media.add_attribute(ssrc)
  end

  defp add_codecs(media, codecs) do
    Enum.reduce(codecs, media, fn
      {_codec, %RTPMapping{} = rtp_mapping}, media ->
        Media.add_attribute(media, rtp_mapping)

      {_codec, {%RTPMapping{} = rtp_mapping, %Fmtp{} = fmtp}}, media ->
        media
        |> Media.add_attribute(rtp_mapping)
        |> Media.add_attribute(fmtp)

      _, _media ->
        raise("Invalid custom codec format")
    end)
  end

  defp get_payload_types(codecs) do
    Enum.reduce(codecs, [], fn
      {_codec, %RTPMapping{payload_type: pt}}, acc -> [pt | acc]
      {_codec, {%RTPMapping{payload_type: pt}, _fmtp}}, acc -> [pt | acc]
      _, _acc -> raise("Invalid custom codec format")
    end)
  end

  defp get_opus(fmt_mappings) do
    %PayloadFormat{payload_type: pt} = PayloadFormat.get(:OPUS)
    %{encoding_name: en, clock_rate: cr} = PayloadFormat.get_payload_type_mapping(pt)
    pt = fmt_mappings[:OPUS] || pt
    rtp_mapping = %RTPMapping{clock_rate: cr, encoding: "#{en}", params: 2, payload_type: pt}
    fmtp = %Fmtp{pt: pt, useinbandfec: true}
    {rtp_mapping, fmtp}
  end

  defp get_h264(fmt_mappings) do
    %PayloadFormat{payload_type: pt} = PayloadFormat.get(:H264)
    %{encoding_name: en, clock_rate: cr} = PayloadFormat.get_payload_type_mapping(pt)
    pt = fmt_mappings[:H264] || pt
    rtp_mapping = %RTPMapping{clock_rate: cr, encoding: "#{en}", payload_type: pt}

    fmtp = %Fmtp{
      pt: pt,
      level_asymmetry_allowed: true,
      packetization_mode: 1,
      profile_level_id: 0x42E01F
    }

    {rtp_mapping, fmtp}
  end

  defp generate_ssrcs(audio_num, video_num) do
    audio_ssrcs = for _audio <- 1..audio_num, do: generate_ssrc()
    video_ssrcs = for _video <- 1..video_num, do: generate_ssrc()
    %{:audio => audio_ssrcs, :video => video_ssrcs}
  end

  defp generate_ssrc(), do: :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned()
end

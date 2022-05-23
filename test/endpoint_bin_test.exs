defmodule Membrane.WebRTC.EndpointBinTest do
  use ExUnit.Case, async: true

  alias Membrane.WebRTC.{EndpointBin, Utils}

  @directions [:sendonly, :recvonly, :sendrecv]

  Enum.map(@directions, fn direction ->
    test "creating #{inspect(direction)} EndpointBin with empty inbound and outbound tracks passes" do
      children = [
        endpoint: %EndpointBin{direction: unquote(direction)}
      ]

      {:ok, _pid} = Membrane.Testing.Pipeline.start_link(children: children)
    end
  end)

  test "creating sendonly EndpointBin with inbound tracks raises an error" do
    track = Utils.get_track()
    options = %EndpointBin{direction: :sendonly, inbound_tracks: [track]}
    assert_raise RuntimeError, fn -> EndpointBin.handle_init(options) end
  end

  test "creating recvonly EndpointBin with outbound tracks raises an error" do
    track = Utils.get_track()
    options = %EndpointBin{direction: :recvonly, outbound_tracks: [track]}
    assert_raise RuntimeError, fn -> EndpointBin.handle_init(options) end
  end

  Enum.map([:recvonly, :sendrecv], fn direction ->
    test "creatinig #{inspect(direction)} EndpointBin with inbound tracks passes" do
      track = Utils.get_track()

      children = [
        endpoint: %EndpointBin{direction: unquote(direction), inbound_tracks: [track]}
      ]

      {:ok, _pid} = Membrane.Testing.Pipeline.start_link(children: children)
    end
  end)

  Enum.map([:sendonly, :sendrecv], fn direction ->
    test "creatinig #{inspect(direction)} EndpointBin with outbound tracks passes" do
      track = Utils.get_track()

      children = [
        endpoint: %EndpointBin{direction: unquote(direction), outbound_tracks: [track]}
      ]

      {:ok, _pid} = Membrane.Testing.Pipeline.start_link(children: children)
    end
  end)

  test "sendonly EndpointBin rejects offer with incoming tracks" do
    test_generating_proper_sdp_answer(:sendonly, :inactive)
  end

  Enum.map([:recvonly, :sendrecv], fn direction ->
    test "#{inspect(direction)} EndpointBin accepts offer with incoming tracks" do
      test_generating_proper_sdp_answer(unquote(direction), :recvonly)
    end
  end)

  test "sendonly EndpointBin raises when receives RTP stream" do
    options = %EndpointBin{direction: :sendonly}
    {{:ok, _spec}, state} = EndpointBin.handle_init(options)

    assert_raise RuntimeError, fn ->
      EndpointBin.handle_notification({:new_rtp_stream, 1234, 96, []}, nil, nil, state)
    end
  end

  defp test_generating_proper_sdp_answer(endpoint_bin_direction, expected_media_direction) do
    # this function creates EndpointBin with direction set to `endpoint_bin_direction`,
    # applies SDP offer and checks correctness of generated SDP answer by asserting
    # against media direction of each m-line i.e. whether it is set to `expected_media_direction`
    offer = File.read!("test/fixtures/2_incoming_tracks_sdp.txt")

    mid_to_track_id = %{
      "0" => "9e9fea81-0f48-4992-a5c2-3e475ca9d5fe:030b4e10-3dc0-4fa5-bf7a-f50f7237ef79",
      "1" => "9e9fea81-0f48-4992-a5c2-3e475ca9d5fe:ea223f51-c234-4431-8218-61b940c7d415"
    }

    fingerprint = Utils.get_cert_fingerprint()

    sdp_offer_msg = {:signal, {:sdp_offer, offer, mid_to_track_id}}
    handshake_init_data_not = {:handshake_init_data, 1, fingerprint}

    options = %EndpointBin{direction: endpoint_bin_direction}
    {{:ok, _spec}, state} = EndpointBin.handle_init(options)
    {:ok, state} = EndpointBin.handle_notification(handshake_init_data_not, nil, nil, state)
    {{:ok, actions}, _state} = EndpointBin.handle_other(sdp_offer_msg, nil, state)

    sdp_answer_action =
      Enum.find(actions, fn action ->
        match?({:notify, {:signal, {:sdp_answer, _answer, _mid_to_track_id}}}, action)
      end)

    {:notify, {:signal, {:sdp_answer, answer, _mid_to_track_id}}} = sdp_answer_action

    ExSDP.parse!(answer)
    |> then(& &1.media)
    |> Enum.each(fn media ->
      assert ExSDP.Media.get_attribute(media, expected_media_direction) ==
               expected_media_direction
    end)
  end
end

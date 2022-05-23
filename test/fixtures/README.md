# Membrane WebRTC Plugin Test Fixtures

List of fixtures used in tests.

SDP offers/answers where generated using [`membrane_videoroom`](https://github.com/membraneframework/membrane_videoroom)
by connecting browser to the server. 

* 2_incoming_tracks_sdp.txt - SDP offer containing two outgoing (i.e. sent by offerer to the peer) tracks:
1 audio and 1 video. It was simplified to contain only one codec for m-line.
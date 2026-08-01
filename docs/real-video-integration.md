# Real robot video integration

The synthetic pipeline is arranged so the Vision Pro receiver remains unchanged when the real robot repositories are ready.

## Replacement map

| Current component | Real integration |
| --- | --- |
| `SyntheticPixelBufferSource` | Cerebro camera callback or camera sample-buffer source |
| `H264VideoEncoder` | Reuse on Apple hosts, or translate another encoder's AVCC output |
| `BoundedInMemoryVideoChannel` | Authenticated network video connection or QUIC stream/datagrams |
| `RobotVideoDataSource` | Robot-side subscription and encoder lifecycle owner |
| `RobotVideoDataTransport` | Controller-side network receive and reassembly adapter |
| `VideoStreamValidator` | Unchanged receiver trust boundary |
| `H264VideoReceiver` and SwiftUI surface | Unchanged Vision Pro decoder and display path |

## Controller adapter contract

A real controller transport conforms to both `RobotTransport` and `RobotVideoDataTransport`. After control-plane negotiation, `RobotSession.openVideoDataStream(for:)` supplies the accepted session and stream descriptor to that adapter and returns a uniquely identified `RobotVideoDataChannel`. The session records the exact transport that owns that token, so later close operations cannot target a replacement connection. The adapter must authenticate the peer, enforce packet and reassembly limits, reject stale sessions, and emit complete `VideoDataMessage` values.

Media must not be published as `RobotEvent` or `RobotSessionSnapshot`; doing so would invalidate the UI at frame rate and could couple video pressure to control processing.

## Robot sender contract

The robot starts capture and encoding only when at least one accepted subscription opens its data stream. Its advertised codecs must be the intersection of camera and encoder support; subscription negotiation must also reject delivery modes the transport cannot provide, and any bitrate ceiling must be enforceable by the encoder. It sends codec configuration immediately before the first IDR and repeats identical same-generation configuration before recovery IDRs. Configuration generation changes only when the parameter-set bytes or NAL-length size changes.

Receiver feedback with `requestsKeyFrame = true` must force the next encoded frame to be an IDR. The encoder and channel stop when the consumer closes its unique channel token, the final subscriber leaves, the control session disconnects, or authorization expires.

## Binary framing still required

`EncodedVideoAccessUnit` represents a reassembled access unit. It is not a network datagram. A network adapter still needs:

- a bounded binary header containing protocol/session/stream identity, frame sequence, fragment index/count, total length, and flags;
- fragmentation appropriate to the selected transport;
- strict maximum frame and fragment counts before allocation;
- timeout and eviction for incomplete frames;
- duplicate and stale-fragment rejection; and
- reassembly into one AVCC access unit before `VideoStreamValidator`.

Do not send production video as JSON/base64, and do not put video fragments on the command queue.

## Safety ordering

Real video integration must not weaken the existing safety contract. Motion commands retain their short leases, Cerebro enforces the definitive receive-side watchdog, and the independently wired physical emergency stop remains authoritative.

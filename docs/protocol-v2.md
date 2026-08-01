# ROB control protocol v2 scaffold

The types in `ROBControlCore` define the domain-level v2 contract. They are not yet a complete network transport. QUIC framing, authentication, and encoded-video fragmentation remain transport work.

## Session handshake

A successful handshake establishes:

- protocol version;
- a fresh, unpredictable session ID;
- robot identity;
- camera and control capabilities; and
- authoritative robot-side safety state.

Every command carries the negotiated session ID and a monotonically increasing sequence. A receiver must reject commands from an old session before interpreting their payload.

## Control envelope

The JSON form uses an explicit command discriminator and Unix epoch milliseconds:

```json
{
  "id": "E0B6A762-59F2-4FEE-8DBA-EE2AA88A6C6A",
  "protocolVersion": 2,
  "sessionID": "3F931C43-3C55-42CE-81CA-1C470FBCC921",
  "sequence": 42,
  "issuedAtUnixMilliseconds": 1785552000000,
  "leaseMilliseconds": 250,
  "command": {
    "type": "drive",
    "motion": {
      "linear": 0.5,
      "angular": -0.25
    }
  }
}
```

`linear` and `angular` are normalized to `-1...1`. Non-finite decoded values fail closed to zero. The robot converts normalized values into its own configured physical limits.

The receive-side processing order must be:

1. authenticate the peer and transport;
2. enforce a strict maximum envelope size;
3. decode the schema and protocol version;
4. validate session ID;
5. validate sequence and lease;
6. validate every payload value; and
7. apply the command.

Emergency stop is idempotent and latched. Reset is a distinct command, leaves motion disarmed, and must never be inferred from reconnecting.

## Video negotiation

`VideoControlMessage` is carried on the reliable control plane:

```text
subscribe(request ID, camera, codecs, constraints, delivery)
    → accepted(stream descriptor)
    → rejected(request ID, reason)

feedback(stream ID, loss, jitter, decoder FPS, desired bitrate, keyframe request)
unsubscribe(stream ID)
```

The request ID correlates the asynchronous response. `RobotSession` applies a two-second negotiation timeout, rejects duplicate active or pending IDs, and does not report success until it receives the matching response. A cancelled or timed-out request is marked abandoned so any late acceptance is immediately unsubscribed. An injected video source narrows advertised camera codecs, rejects unsupported delivery modes during subscription negotiation, and caps the accepted descriptor at its maximum bitrate.

Encoded video data is intentionally absent from control messages. The separate data plane models two explicitly tagged messages:

```text
codecConfiguration(session, stream, codec, generation, SPS/PPS, NAL length size)
accessUnit(session, stream, codec, sequence, capture time, PTS, duration,
           keyframe flag, configuration generation, payload)
```

H.264 payloads are complete AVCC length-prefixed access units, not individual NAL units and not Annex-B byte streams. Each opened channel has a unique token in addition to its session and subscription identities. Direct decoding drops harmless stale or reordered traffic, rejects malformed length prefixes and configuration conflicts, and suppresses predictive frames received after a sequence gap. SPS-derived coded and clean-aperture dimensions are checked against the negotiated descriptor before decoder allocation.

Current hard limits are 2 MiB per access unit, 64 KiB per codec configuration, 3 MiB per serialized compatibility envelope, 4096 pixels per dimension, 8,847,360 decoded pixels, 240 frames per second, and 1 Gbit/s. `VideoDataMessageCodec` provides bounded JSON for tests and compatibility work; a production adapter should use binary framing rather than base64 JSON for media.

The transport below this model must fragment access units that exceed its packet size and must reassemble one complete validated access unit before decoding. Control commands and video fragments must never share a queue that allows media congestion to delay stop traffic.

## Compatibility

The future `LegacyAutoNetAdapter` should translate between these types and the existing robot wire representation. Legacy keyed archives, service-name inconsistencies, and native-endian framing must remain private implementation details of that adapter and must not become v2 protocol behavior.

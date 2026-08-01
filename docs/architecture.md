# Architecture

## Dependency direction

```text
SwiftUI views
    └──► RobotViewModel ───► GameControllerInput
              │
              ├──► RobotSession actor ───► RobotTransport
              │         (ROBControlCore)       ├── SimulatedRobotEndpoint
              │                                ├── LegacyAutoNetAdapter  planned
              │                                └── QUICRobotTransport    planned
              │
              └──► VideoPipelineCoordinator
                        └──► H264VideoReceiver (ROBVideoPipeline)
```

`ROBControlCore` imports only Foundation. SwiftUI, GameController, Network.framework, VideoToolbox, and AVFoundation adapters remain outside the core package so its state machines and wire-domain types stay independently testable.

`ROBVideoPipeline` is a second Swift package target. It imports Core Video, VideoToolbox, Core Media, and AVFoundation without inheriting the app target's main-actor default. The app target owns only observable lifecycle state and the SwiftUI/UIView display wrapper.

## Concurrency boundaries

- `RobotViewModel` and `GameControllerInput` are main-actor isolated.
- `RobotSession` is an actor and is the sole owner of connection transitions, command sequence allocation, and dead-man state.
- Connect and disconnect operations carry identities and are revalidated after every suspension. Concurrent disconnect callers share one teardown, reconnect cannot race that teardown, and a late acceptance for a cancelled video request is immediately unsubscribed.
- Every transport is `Sendable`; the simulator is an actor.
- Views consume a bounded, newest-value `AsyncStream<RobotSessionSnapshot>` rather than observing transport callbacks directly.
- Synthetic generation is actor-confined. VideoToolbox callbacks copy encoded bytes immediately into `Sendable` value types, and a hard pixel-buffer allocation threshold drops capture attempts if encoding falls behind.
- Every open media channel has a unique ownership token. Session and endpoint state are revalidated after asynchronous opens, preventing stale reconnect work from escaping or closing a replacement channel.
- The receiver enqueues media directly into `AVSampleBufferVideoRenderer`; only throttled statistics reach Observation and SwiftUI. SPS-derived coded and presentation dimensions must match the negotiated stream before decoder use.

## Safety contract

Every drive envelope contains a monotonically increasing sequence number and a short lease in milliseconds. The controller sends decisions at 10 Hz by default. The simulator stops when the lease or its own watchdog expires.

Emergency stop is latched. Reconnection, controller discovery, or scene reactivation cannot clear it. Resetting emergency stop leaves motion disarmed and requires a separate arm action.

The application scene invalidates motion on inactive/background transitions. Physical game-controller samples are event-driven: stale framework state is not promoted into fresh operator intent.

## Connection state

The session publishes explicit phases:

```text
disconnected → connecting → handshaking → connected
      ▲                                      │
      └──────────── disconnecting ◄──────────┘

Any active phase may enter failed.
```

Readiness means both the transport and capability handshake completed; callers never infer readiness from discovery alone.

## Video protocol

The reliable control plane negotiates a `VideoSubscriptionRequest` and receives a `VideoSubscriptionResponse`. The selected `VideoStreamDescriptor` identifies codec, dimensions, frame rate, bitrate, and delivery mode. The simulator accepts only codecs and delivery modes published by its injected source and clamps bitrate to that source's maximum. Receiver feedback can report loss, jitter, decoder rate, desired bitrate, and keyframe requests.

Implemented simulator data path:

```text
accepted subscription
    ▼
SyntheticPixelBufferSource (pooled BGRA frames)
    ▼
VideoToolbox real-time H.264 encoder
    ▼
BoundedInMemoryVideoChannel (drop-oldest, nonblocking)
    ▼
VideoStreamValidator + H264SampleBufferFactory
    ▼
AVSampleBufferDisplayLayer.sampleBufferRenderer
```

Production replacement path:

```text
Cerebro camera sample buffer
    ▼
VideoToolbox H.264 encoder
    ▼
bounded video transport (separate from control)
    ▼
visionOS decoder / AVSampleBufferDisplayLayer
```

The implemented pipeline starts when an accepted subscription opens its data stream, forces a keyframe on start and recovery, and stops on consumer cancellation, scene inactivity, unsubscribe, or disconnect. A sequence gap invalidates predictive frames until another IDR arrives. Duplicate and reordered datagrams are dropped without terminating the receiver; malformed current-stream media still fails closed.

## Integration sequence

1. Keep the implemented synthetic H.264 source as the deterministic development and UI-test endpoint.
2. Add `LegacyAutoNetAdapter` without exposing legacy message shapes outside the adapter.
3. Add a receive-side watchdog to the real robot host before enabling motion.
4. Introduce authenticated QUIC/TLS discovery, pairing, and capability negotiation.
5. Replace `SyntheticPixelBufferSource` with the existing robot camera source and reuse or adapt the encoder.
6. Replace `BoundedInMemoryVideoChannel` with binary network fragmentation/reassembly beneath `VideoDataMessage`.
7. Move stable protocol targets into a versioned shared repository when `ROBController` and `Cerebro` are ready to consume them.

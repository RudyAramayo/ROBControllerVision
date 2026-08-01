# ROBControllerVision

`ROBControllerVision` is an isolated, native SwiftUI controller scaffold for Apple Vision Pro. It currently drives a deterministic simulated robot and does not modify or depend on the active `ROBController` or `Cerebro` repositories.

## Included

- A visionOS 2.0 `WindowGroup` dashboard with connection, telemetry, safety, motion, and video panels.
- A pure-Foundation Swift 6 target, `ROBControlCore`, containing transport abstractions, connection/session state, control leases, dead-man evaluation, video protocol messages, and the simulator.
- A separate `ROBVideoPipeline` target containing the pooled synthetic source, VideoToolbox encoder, bounded channel, sample reconstruction, and AVFoundation receiver.
- Physical game-controller input through GameController. Hold **A** or the right trigger while using the left thumbstick.
- Press-and-hold spatial controls for simulator operation without a gamepad.
- A latched software emergency stop and explicit reset/disarm flow.
- Dynamic video subscription negotiation plus a complete synthetic camera path: reusable pixel buffers, real-time H.264 encoding, a bounded data channel, validated access units, system decoding, and live SwiftUI display.
- Package tests covering safety boundaries, connection state, simulator watchdog behavior, reconnect behavior, bounded video transport, wire validation, real H.264 encoding, sample reconstruction, and negotiated streaming.

## Open and run

1. Open `ROBControllerVision.xcodeproj` in Xcode 26 or newer.
2. Select the `ROBControllerVision` scheme.
3. Choose an Apple Vision Pro simulator or a provisioned device.
4. Run the app and select **Connect Simulator**.
5. Select **Subscribe** to start the synthetic H.264 camera stream.
6. Arm motion, then hold a directional control. Release it to stop.

Command-line validation:

```bash
swift test --package-path Packages/ROBControlCore

xcodebuild \
  -project ROBControllerVision.xcodeproj \
  -scheme ROBControllerVision \
  -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/ROBControllerVisionDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The current placeholder bundle identifier is `com.raramayo.ROBControllerVision`. Change it and select your development team before installing on a physical device.

## Safety behavior

Motion is inhibited by default. The operator must connect, arm motion, and continuously provide fresh input while holding a dead-man control. `ROBControlCore` stops motion when:

- the 250 ms input lease expires;
- the dead-man control is released;
- the application scene becomes inactive;
- the controller disconnects;
- the transport fails;
- the operator disarms motion; or
- the emergency stop is latched.

The simulated endpoint independently enforces a receive-side command watchdog. A production integration must add the equivalent watchdog to `Cerebro`; an app-only dead-man cannot stop a robot after total network loss. The software stop control supplements and never replaces a physical, independently wired emergency stop.

On visionOS, game-controller delivery depends on the app receiving controller events. This scaffold intentionally treats missing fresh callbacks as expired input instead of replaying a retained thumbstick value. Validate the interaction and gaze/focus behavior on the target Vision Pro and controller before real-robot use.

## Video implementation

The simulator exercises this complete encoded-video path:

```text
SyntheticPixelBufferSource
    → VideoToolbox H.264 encoder
    → bounded in-memory video data channel
    → session/stream/access-unit validator
    → AVSampleBufferVideoRenderer decoder
    → SwiftUI video surface
```

The source starts only after a subscription is accepted and a controller opens the video data stream. It stops when the display consumer closes, the scene becomes inactive, the operator unsubscribes, or the session disconnects. Each open receives a unique channel token, so delayed cleanup from an old session cannot close a replacement stream. Video uses a separate nonblocking channel, so queue pressure cannot delay drive or emergency-stop messages. Normal encoder and channel pressure drops media instead of terminating the stream; the receiver suppresses dependent frames and requests a new IDR keyframe after a gap or decoder flush.

The in-memory channel is the network stand-in. It carries the same session-bound codec-configuration and access-unit messages that a future authenticated network adapter will serialize, fragment, reassemble, and validate. Advertised simulator codecs are intersected with the injected source's actual capabilities; requested delivery modes are enforced during subscription negotiation, and the accepted bitrate is clamped to the source limit. It does not pretend that large H.264 access units fit in one network datagram.

## Video protocol

Video subscription control is already modeled with:

- camera and codec capabilities;
- preferred codecs;
- maximum resolution, frame rate, and bitrate;
- delivery mode;
- accept/reject responses;
- unsubscribe requests; and
- receiver feedback and keyframe requests.

Subscription messages belong on the reliable control channel. Encoded frames use the separate `RobotVideoDataTransport` boundary. See [the architecture notes](docs/architecture.md) and [real-robot integration guide](docs/real-video-integration.md) for the replacement points.

The tagged JSON envelope, session, lease, and negotiation rules are documented in [the v2 protocol scaffold](docs/protocol-v2.md).

## Repository boundary

This repository contains no source references to `../ROBController` or `../Cerebro`. A future `LegacyAutoNetAdapter` can be added behind the `RobotTransport` protocol after the concurrent changes in those repositories settle. Do not copy their current keyed-archive wire representation into the core domain model.

# ROBControllerVision

`ROBControllerVision` is a native SwiftUI controller for Apple Vision Pro. It can connect to a real Cerebro host over authenticated QUIC/TLS or run against the deterministic simulator for development and UI testing.

## Included

- A visionOS 2.0 `WindowGroup` dashboard with connection, safety, motion, video, and simulator-telemetry panels. Cerebro's legacy application messages are not yet mapped into `RobotTelemetry`, so the real endpoint leaves those telemetry fields empty.
- `ROBControlCore`, a pure-Foundation Swift 6 target containing transport abstractions, connection/session state, control leases, dead-man evaluation, video-domain messages, and the simulator.
- `ROBCerebroTransport`, the Network.framework and Security.framework adapter for Cerebro pairing, discovery, reciprocal authentication, established ROBController control payloads, and the separate video service.
- `ROBVideoPipeline`, containing the pooled synthetic source, VideoToolbox encoder, bounded simulator channel, strict H.264 receiver, and AVFoundation display path.
- Physical game-controller input through GameController. Hold **A** or the right trigger while using the left thumbstick.
- Press-and-hold spatial controls for operation without a gamepad.
- A latched software emergency stop and explicit reset/disarm flow.
- Demand-driven Cerebro H.264 streaming plus a complete synthetic H.264 path for offline testing.

## Connect to Cerebro

The Vision Pro and Cerebro Mac must be on the same local network. `_robctl._udp` is required for robot control. Cerebro must also have a working camera source and advertise `_robvideo._udp` for the Vision app to offer video:

```text
_robctl._udp   / robctl/2    authenticated robot control and live session
_robvideo._udp / robvideo/1  authenticated video negotiation and H.264 media
```

Pair and connect as follows:

1. In Cerebro, open **Manage Paired Devices…** and choose **Pair ROBController**.
2. Enter a recognizable name such as **Apple Vision Pro**. Create a new code for this device even if another ROBController is already paired.
3. On Vision Pro, choose **Cerebro**, select **Pair Cerebro**, and paste the complete `ROBCTL2:...` enrollment code.
4. Select **Install pairing code**. The credential and Cerebro certificate pin are stored in this Vision Pro's Keychain. The pairing status reads **Credential installed** at this point; installation alone has not authenticated Cerebro.
5. Accept the visionOS Local Network permission prompt, then select **Connect Cerebro**.
6. After the control connection authenticates, the pairing status reads **Connected and verified**. If Cerebro's video service also authenticated and advertised a camera, select **Subscribe** in the Robot Camera panel. The app requests the `front` camera as H.264 at up to 960 x 540, 20 fps, and 1.5 Mbit/s using `reliableStream` delivery.
7. Arm motion, then hold a directional control or use a game controller while holding its dead-man control. Release it to stop.

Each physical controller must have its own Cerebro-issued credential. Do not reuse the iPhone ROBController code or copy its Keychain item to Vision Pro. Reusing a code clones the controller identity, prevents independent revocation, and can cause Cerebro's duplicate-session protection to reject one of the devices.

### Certificate migration warning

Cerebro now keeps one canonical server certificate and uses it for control, video, Bonjour identity material, and every pairing code. The first launch after adopting that identity fix can intentionally replace an older leaf certificate, making every pre-upgrade certificate pin stale.

If this is that first migrated launch, revoke the old Vision Pro entry in **Manage Paired Devices…**, issue a fresh **Pair ROBController** code, and install it in the Vision app before connecting. Reinstalling the fresh code intentionally replaces the app's single local Keychain profile. Do not disable certificate pinning as a workaround. After migration, an ordinary Cerebro restart must keep the same certificate fingerprint; an unexpected later change should be investigated before re-pairing devices.

## Run the simulator

1. Open `ROBControllerVision.xcodeproj` in Xcode 26 or newer.
2. Select the `ROBControllerVision` scheme and a Vision Pro simulator or provisioned device.
3. Run the app, choose **Simulator**, and select **Connect Simulator**.
4. Select **Subscribe** to start the synthetic H.264 stream.
5. Arm motion, then hold a directional control. Release it to stop.

The simulator remains available after a Cerebro credential is installed; use the endpoint picker while disconnected.

## Command-line validation

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

The placeholder bundle identifier is `com.raramayo.ROBControllerVision`. Change it and select your development team before installing on a physical device.

Automated package and simulator-build checks validate the state machines, wire codecs, and compilation boundaries. They do not replace a two-device smoke test of Bonjour, Local Network permission, Cerebro camera capture, certificate pinning, video recovery, robot watchdog behavior, and the physical emergency stop.

## Safety behavior

Motion is inhibited by default. The operator must connect, arm motion, and continuously provide fresh input while holding a dead-man control. `ROBControlCore` stops motion when:

- the 250 ms input lease expires;
- the dead-man control is released;
- the application scene becomes inactive;
- the controller disconnects;
- the transport fails;
- the operator disarms motion; or
- the emergency stop is latched.

The simulator independently enforces a receive-side watchdog. Cerebro remains the authoritative real-robot receiver and must independently stop on stale or disconnected controller input; an app-only dead-man cannot stop a robot after total network loss. The software stop control supplements and never replaces a physical, independently wired emergency stop.

While a game-controller dead-man is held, ROBControllerVision also recenters on
the current Vision Pro head pose and sends bounded relative yaw and pitch as the
camera-neck demand. Releasing the dead-man, losing device-anchor tracking, leaving
the active scene, or disconnecting stops publishing neck demands. Cerebro applies
them only from its fresh master-controller snapshot and mirrors the accepted
pan/tilt on its SceneKit diagnostic robot.

PSVR Sense index triggers are reserved for the matching Amber grippers: pressed
requests closed and released requests open. Both VR grip buttons must remain held
as the continuous dead-man gesture, and the app's **Arm Motion** control must also
be unlocked. A conventional gamepad uses A or both shoulder buttons for the
continuous hold. Cerebro emits gripper operations only on state transitions and
labels them as commanded rather than measured feedback.

With the same dead-man hold, Vision Pro yaw beyond the camera neck's 60-degree
range produces a bounded rotating-torso demand. Cerebro owns the Pololu Tic USB
safety sequence and position conversion; ROBControllerVision never sends shell
commands or confuses this rotating plate with ROB's separate lean LACT.

On visionOS, game-controller delivery depends on the app receiving controller events. Missing fresh callbacks are treated as expired input instead of replaying a retained thumbstick value. Validate controller delivery, gaze/focus behavior, the Cerebro watchdog, and the physical stop on the target hardware before real-robot use.

## Network and video implementation

The production connections are deliberately separate:

```text
Vision control domain
    → CerebroRobotTransport
    → _robctl._udp / robctl/2 / pinned TLS 1.3
    → reciprocal HMAC proof
    → exact live control-session UUID

Vision video request
    → optional _robvideo._udp / robvideo/1 / the same certificate pin
    → video-specific reciprocal HMAC proof
    → capabilities and reliableStream subscription carrying that exact UUID
    → RVID-framed RBVD codec configuration and AVCC H.264 access units
    → session/stream/access-unit validator
    → AVSampleBufferVideoRenderer
    → SwiftUI video surface
```

Video capabilities, subscribe/response, feedback, unsubscribe, codec configuration, access units, and stream-ended events all travel on `_robvideo._udp`. They are not sent over the physical `_robctl._udp` connection. The exact live control-session UUID binds the independent video connection to the authenticated operator; disconnecting control, replacing its session, revoking the credential, suspending the app, or unsubscribing tears down video. Video discovery, authentication, or runtime failure removes video availability or ends active streams but leaves authenticated robot control connected.

The simulator uses the same session and decoder boundaries but replaces the network adapter with `SyntheticPixelBufferSource`, a real-time VideoToolbox encoder, and `BoundedInMemoryVideoChannel`. Normal encoder or channel pressure drops media rather than delaying motion or stop commands. Sequence gaps suppress predictive frames and request a new IDR keyframe.

See [the architecture notes](docs/architecture.md), [Cerebro video integration guide](docs/real-video-integration.md), and [protocol mapping](docs/protocol-v2.md).

## Diagnostics

From another Mac on the same LAN, run each browser in a separate Terminal window:

```bash
dns-sd -B _robctl._udp local.
dns-sd -B _robvideo._udp local.
```

Cerebro should report its control service as ready using `robctl/2` and, when camera viewing is available, its video service using `robvideo/1`. If neither service appears, verify that both devices are on the same LAN, Local Network access is allowed for ROBControllerVision, Cerebro is running, and the host firewall permits the services.

The Cerebro endpoint treats video as optional for safety. If `_robctl._udp` authenticates but video discovery or authentication fails, **Connect Cerebro** still succeeds with no advertised cameras and control remains available. The current session does not hot-add a later video service; after `_robvideo._udp` becomes healthy, disconnect and reconnect to refresh the one-time camera capabilities.

If control connects but the camera is absent or **Subscribe** remains unavailable, verify `_robvideo._udp`, its authentication, and Cerebro's selected camera. An unavailable video service or camera produces a control handshake with no cameras, so reconnect after correcting the video state.

If pinned TLS or reciprocal authentication fails immediately after the Cerebro canonical-certificate migration, revoke the stale Cerebro device entry and install a newly issued code. If video reports an authorization or stale-session failure, disconnect both connections and reconnect control before subscribing; never substitute a locally generated session UUID.

## Repository boundary

The repository is self-contained and has no source-path dependency on sibling `ROBController` or `Cerebro` checkouts. `ROBCerebroTransport` keeps Cerebro's wire framing, pairing material, and established keyed-archive controller compatibility private behind `RobotTransport`; those legacy shapes do not leak into the `ROBControlCore` domain model.

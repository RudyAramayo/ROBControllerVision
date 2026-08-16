# ROBControllerVision

`ROBControllerVision` is a native SwiftUI controller for Apple Vision Pro. It can connect to a real Cerebro host over authenticated QUIC/TLS or run against the deterministic simulator for development and UI testing.

## Included

- A visionOS 2.0 `WindowGroup` dashboard with connection, safety, motion, video, and telemetry panels. Cerebro's legacy base telemetry is not yet mapped into `RobotTelemetry`, but authenticated seven-joint Amber arm feedback appears independently in `RobotSessionSnapshot.armTelemetry`.
- `ROBControlCore`, a pure-Foundation Swift 6 target containing transport abstractions, connection/session state, control leases, dead-man evaluation, video-domain messages, and the simulator.
- `ROBCerebroTransport`, the Network.framework and Security.framework adapter for Cerebro pairing, discovery, reciprocal authentication, established ROBController control payloads, and the separate video service.
- `ROBVideoPipeline`, containing the pooled synthetic source, VideoToolbox encoder, bounded simulator channel, strict H.264 receiver, and AVFoundation display path.
- Physical game-controller input through GameController. Hold **A** or the right trigger while using the left thumbstick.
- Press-and-hold spatial controls for operation without a gamepad.
- A latched software emergency stop and explicit reset/disarm flow.
- Demand-driven Cerebro H.264 streaming plus a complete synthetic H.264 path for offline testing.
- Supervised `rob-arm-control/2` Amber arm control with measured seven-joint feedback, independent time-limited Cerebro authority for each arm, independent on-screen joint controls, simultaneous paired PSVR Sense thumbstick jogging, measured completion, and priority hold commands. Arm activation and actuator-mode changes remain outside the Vision app.
- A default-off, authenticated action-approval console for reviewing bounded Cerebro proposals, explicitly approving or rejecting them, cancelling active work, and observing Cerebro-owned measured completion for approved Amber gestures.

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
7. Select **Enable Drive Control**, then hold a directional control or use a game controller while holding its dead-man control. Release it to stop.
8. Open **Amber Arm Control**, initialize each arm you intend to use from fresh measured feedback, and request **Enable Arm Control** separately for the left and right arms. Cerebro grants independent authorities and measured baselines, so either or both on-screen joint controls can run. With both authorities active, two connected PSVR Sense controllers can jog the matching selected joints simultaneously while both grip buttons are held.
9. For Cerebro/Gemini action proposals, explicitly enable **Cerebro Action Approval**. Inspect each immutable, expiring proposal and choose **Approve** or **Reject**. Gesture approval authorizes one named catalog gesture; it never accepts model-supplied joint values.

Each physical controller must have its own Cerebro-issued credential. Do not reuse the iPhone ROBController code or copy its Keychain item to Vision Pro. Reusing a code clones the controller identity, prevents independent revocation, and can cause Cerebro's duplicate-session protection to reject one of the devices.

### Certificate migration warning

Cerebro now keeps one canonical server certificate and uses it for control, video, Bonjour identity material, and every pairing code. The first launch after adopting that identity fix can intentionally replace an older leaf certificate, making every pre-upgrade certificate pin stale.

If this is that first migrated launch, revoke the old Vision Pro entry in **Manage Paired Devices…**, issue a fresh **Pair ROBController** code, and install it in the Vision app before connecting. Reinstalling the fresh code intentionally replaces the app's single local Keychain profile. Do not disable certificate pinning as a workaround. After migration, an ordinary Cerebro restart must keep the same certificate fingerprint; an unexpected later change should be investigated before re-pairing devices.

## Run the simulator

1. Open `ROBControllerVision.xcodeproj` in Xcode 26 or newer.
2. Select the `ROBControllerVision` scheme and a Vision Pro simulator or provisioned device.
3. Run the app, choose **Simulator**, and select **Connect Simulator**.
4. Select **Subscribe** to start the synthetic H.264 stream.
5. Select **Enable Drive Control**, then hold a directional control. Release it to stop. The simulator deliberately does not advertise or accept physical Amber arm authority.

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

Amber arm motion has a separate control domain that is mutually exclusive with
drive control. The current Cerebro transport profile enables `rob-arm-control/2`;
the simulator does not. After drive control is disarmed, Cerebro can grant
independent, time-limited authorities for the left and right arms. Each arm keeps
its own measured baseline, selected joint, draft, status, in-flight target, and
authority lease. Its on-screen hold-to-move control can run independently of the
other arm; releasing it requests an ordinary measured-position hold for that arm.

Paired PSVR Sense jogging is available with the arm panel open only after both
controllers are connected, both arm authorities are granted, both arms have
feedback no more than 250 ms old, and all seven joints on each arm are verified in
position mode. The left and right vertical thumbsticks jog the matching arm's
selected joint simultaneously. A 0.15 dead zone is applied, the other six joints
are copied from the latest measured sample, and every target remains within the B1
limit, 0.08-radian increment, 0.20-radian/second rate, and short per-arm lease.
Both grip buttons form one paired dead-man: releasing either grip stops both jog
loops and requests ordinary holds for both arms while retaining their authorities,
so motion requires a deliberate fresh two-grip hold to resume.

A controller disconnect, more than 250 ms without a fresh controller sample,
stale arm telemetry, mode/preflight loss, target timeout or send failure, scene
loss, stop, disarm, or software E-stop uses the priority path to hold and locally
disarm both arms. **Priority Hold Both Arms** remains available while connected.
Network loss still requires Cerebro and the Amber gateway to enforce their
independent per-arm lease expiry and hold behavior. This workflow is measured
joint jogging; tracked controller poses are diagnostic data and are not converted
into Cartesian targets or IK puppeteering.

Action approval is independent and off by default. When enabled, Vision sends a
short-lived availability hello bound to its authenticated controller identity;
scene loss, disconnect, software E-stop, or disabling the console withdraws that
availability and cancels any pending proposal. Requests have strict action-specific
argument schemas and an expiry, and are shown only when addressed to this exact
controller. `play_gesture` can name only an approved Cerebro catalog entry. After
operator approval Cerebro owns leased execution, holds on failure, and reports
completion only after fresh Amber feedback settles. Other bounded actions remain
manually supervised and expose explicit **Confirm Completed** / **Report Failed**
controls.

The simulator independently enforces a receive-side watchdog. Cerebro remains the authoritative real-robot receiver and must independently stop on stale or disconnected controller input; an app-only dead-man cannot stop a robot after total network loss. The software stop control supplements and never replaces a physical, independently wired emergency stop.

While a game-controller dead-man is held, ROBControllerVision also recenters on
the current Vision Pro head pose and sends bounded relative yaw and pitch as the
camera-neck demand. Releasing the dead-man, losing device-anchor tracking, leaving
the active scene, or disconnecting stops publishing neck demands. Cerebro applies
them only from its fresh master-controller snapshot and mirrors the accepted
pan/tilt on its SceneKit diagnostic robot.

PSVR Sense index triggers are reserved for the matching Amber grippers: trigger
edges request bounded `hold` or `release` actions at the selected raw vendor
intensity. Both VR grip buttons must remain held as the gripper dead-man gesture;
this direct gripper lane does not require **Enable Drive Control**. Cerebro and the
gateway require a session-local calibration acknowledgement before control, emit
operations only on state transitions, and label every result as commanded rather
than measured position, force, or completion feedback.

With the same dead-man hold, Vision Pro yaw beyond the camera neck's 60-degree
range produces a bounded rotating-torso demand. Cerebro owns the Pololu Tic USB
safety sequence and position conversion; ROBControllerVision never sends shell
commands or confuses this rotating plate with ROB's separate lean LACT.

On visionOS, game-controller delivery depends on the app receiving controller events. The current physical input profile is reread every 50 ms so a deliberately held grip/stick renews the dead-man sample; if that polling/callback path stops for more than 250 ms, paired arm jogging expires and takes the priority-hold path. Validate controller delivery, gaze/focus behavior, the Cerebro watchdog, and the physical stop on the target hardware before real-robot use.

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

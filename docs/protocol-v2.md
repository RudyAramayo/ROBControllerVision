# ROB control domain and Cerebro v2 mapping

`ROBControlCore` defines the controller's transport-independent domain contract. `ROBCerebroTransport` now supplies the production mapping to Cerebro's authenticated `robctl/2` and `robvideo/1` services. The simulator implements the same domain protocols without a network.

These layers are intentionally distinct:

```text
RobotCommandEnvelope / VideoControlMessage       ROBControlCore domain
                    │
                    ├── simulator actor + in-memory H.264 channel
                    └── CerebroRobotTransport
                           ├── RCTL v2 control framing + established controller payload
                           └── RVID v1 video framing + RBVD binary media
```

The JSON examples below specify domain semantics and fixture encoding. They are not sent verbatim as Cerebro application payloads.

## Pairing and transport authentication

Cerebro issues one `ROBCTL2:...` enrollment code for one physical controller. ROBControllerVision accepts only an `operatorController` profile and stores the exact robot UUID, controller UUID, certificate SHA-256 pin, secret, role, and metadata in one Keychain record. Installing a new valid profile updates that record; the app has no API that creates a Cerebro server identity or certificate. The UI distinguishes persisted from authenticated state: **Credential installed** means Keychain storage succeeded, while **Connected and verified** appears only after the control certificate and reciprocal proof succeed.

Control discovery browses `_robctl._udp`, then filters for the installed `robot_id`, `ver=2`, and `alpn=robctl/2`. Bonjour metadata is routing information only. The client pins the enrolled leaf certificate, establishes TLS 1.3 QUIC, and completes reciprocal HMAC-SHA-256 challenge/proof before sending application data.

Video independently browses `_robvideo._udp` and uses ALPN `robvideo/1`, the same certificate pin, and a video-domain reciprocal proof. A control proof is not valid on the video service. Failure to discover or authenticate this optional connection yields no camera capabilities; it does not fail an authenticated `robctl/2` session.

Every controller needs a unique enrollment code. Copying a ROBController credential to Vision Pro clones the same authenticated controller UUID and can trigger duplicate-session rejection. If Cerebro's one-time canonical-certificate migration changed the leaf pin, revoke the stale device record and install a fresh Cerebro-issued code; never disable pin validation or automatically trust a replacement certificate.

## Session handshake

A successful core handshake establishes:

- protocol version;
- Cerebro's fresh, unpredictable live control-session UUID;
- robot identity;
- control capabilities and any cameras obtained from the optional video service; and
- authoritative robot-side safety state.

For the simulator, the endpoint creates that UUID. For Cerebro, `CerebroRobotTransport` must use the 16 session bytes from the authenticated `robctl/2` challenge exactly. It must not synthesize a second production session ID.

Every domain command carries the negotiated session ID and a monotonically increasing sequence. A receiver rejects commands from an old session before interpreting their payload. The same exact UUID is included in production video subscribe, feedback, unsubscribe, and media identities so Cerebro can bind the independent video connection to the current operator control session.

## Domain control envelope

The domain JSON form uses an explicit command discriminator and Unix epoch milliseconds:

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

`linear` and `angular` are normalized to `-1...1`. Non-finite decoded values fail closed to zero. The robot converts normalized values into its configured physical limits.

For production, `CerebroRobotTransport` validates the domain envelope and translates motion-authority and controller-snapshot operations into Cerebro's established ROBController application payload. That compatibility payload is carried inside authenticated, ordered `RCTL` v2 QUIC frames. Historical keyed dictionaries and the fourteen-line controller snapshot remain private to `ROBCerebroTransport`; they are not the `ROBControlCore` schema and must not be used by new UI or safety code.

Receive-side processing follows this order:

1. authenticate the peer and physical transport;
2. enforce the physical frame-size limit;
3. decode the frame/schema and protocol version;
4. validate authenticated role and message kind;
5. validate the current session and command sequence/lease;
6. validate every payload value; and
7. apply the command.

Emergency stop is idempotent and latched. Reset is distinct, leaves motion disarmed, and must never be inferred from reconnecting. Cerebro's receive-side watchdog remains definitive when a real transport disappears.

## Video negotiation

`VideoControlMessage` models these operations at the `RobotSession` boundary:

```text
subscribe(request ID, camera, codecs, constraints, delivery)
    → accepted(stream descriptor)
    → rejected(request ID, reason)

feedback(stream ID, loss, jitter, decoder FPS, desired bitrate, keyframe request)
unsubscribe(stream ID)
```

The physical routing depends on the endpoint:

- The simulator handles negotiation in its actor and opens `BoundedInMemoryVideoChannel`.
- `CerebroRobotTransport` sends capabilities, subscribe/response, feedback, unsubscribe, and stream-ended control messages on the authenticated `_robvideo._udp` connection.

Production video negotiation does **not** use the `_robctl._udp` connection. The phrase "control message" here means a low-rate video-domain operation, not the physical robot-control channel.

The request ID correlates the asynchronous response. `RobotSession` applies a bounded negotiation timeout, rejects duplicate active or pending IDs, and does not report success until it receives the matching response. A cancelled or timed-out request is abandoned so a late acceptance is immediately unsubscribed.

Cerebro currently advertises camera `front`, H.264, and `reliableStream`. ROBControllerVision requests up to 960 x 540, 20 fps, and 1,500,000 bit/s; the accepted `VideoStreamDescriptor` is authoritative because the server may clamp the request. QUIC datagram, HEVC, and JPEG requests are rejected for this production profile.

## Encoded video data

The video data plane maps two explicitly tagged domain messages:

```text
codecConfiguration(session, stream, codec, generation, SPS/PPS, NAL length size)
accessUnit(session, stream, codec, sequence, capture time, PTS, duration,
           keyframe flag, configuration generation, payload)
```

On the Cerebro wire, each message is one bounded payload in a 32-byte ordered `RVID` frame. Media payloads begin with a fixed 92-byte network-byte-order `RBVD` header. Configuration carries raw SPS/PPS records; an access-unit message carries one complete AVCC length-prefixed H.264 access unit. It is not JSON/base64 and is never an Annex-B stream.

The `RVID` Network.framework framer delivers complete reliable-stream application messages. Application-level datagram fragmentation and reassembly are not used in this version. The control and media connections remain separate so media congestion cannot delay a stop command.

Each opened core channel has a unique ownership token in addition to its session and subscription identities. Direct decoding drops harmless stale or reordered traffic, rejects malformed length prefixes and configuration conflicts, and suppresses predictive frames after a sequence gap. SPS-derived coded and clean-aperture dimensions are checked against the negotiated descriptor before decoder allocation. Receiver loss requests cause feedback with `requestsKeyFrame = true` on `_robvideo._udp`.

Current hard limits include:

- 64 KiB for one video JSON control message or codec configuration;
- 2 MiB for one encoded access unit;
- 960 x 540, 20 fps, and 1,500,000 bit/s for the Cerebro profile; and
- broader `ROBControlCore` defensive ceilings of 4096 pixels per dimension, 8,847,360 decoded pixels, 240 fps, and 1 Gbit/s before a transport-specific profile is applied.

## Lifecycle and failure behavior

The video subscription is valid only while its exact control session remains live for the same authenticated `operatorController`. A stale or locally generated UUID, `lidarPublisher` credential, revoked credential, mismatched stream ID, unsupported profile, malformed payload, or replaced control session fails closed.

Scene suspension, disconnect, unsubscribe, stream-ended notification, or fatal receiver validation closes the uniquely owned media channel. Control disconnect tears down video. Video discovery/authentication failure produces a ready control handshake with no cameras, and runtime video loss ends its streams without closing, arming, resetting, or otherwise altering control. Capabilities are not hot-refreshed; restore video and reconnect the Cerebro endpoint to advertise cameras in a new handshake.

## Compatibility boundary

The production adapter deliberately contains Cerebro's established controller payload rather than changing the core model to match it. New protocol work should extend typed domain messages and add a narrow adapter mapping. It must not leak keyed archives, native implementation details, or service-name compatibility behavior into `ROBControlCore`.

## Supervised Amber arm control

The authenticated control connection also carries the narrow
`rob-arm-control/2`, schema-version 2 JSON subprotocol. Cerebro publishes bounded
seven-joint measured position, velocity, current, status, and actuator-mode
telemetry for each arm.
`CerebroRobotTransport` converts those messages into `RobotEvent.armTelemetry`,
and `RobotSessionSnapshot.armTelemetry` retains only increasing sequences plus
their local monotonic receipt times.

An `authority_intent` acquires 60–600 seconds of server-owned authority for one
arm or releases it with the fixed 1-second release lease. Cerebro returns an
`authority_state` (`granted`, `released`, `rejected`, or `expired`) correlated to
the exact controller, live session, request, and arm. A grant includes its
authority UUID, expiry, captured seven-joint measured baseline and sequence, and
seven actuator modes. Left and right authority state is independent: the same
authenticated session may hold both grants, and each arm retains its own lease,
active target, disposition, and measured-completion gate. Commands share one
session-global increasing sequence so concurrent arm loops cannot create replay
ambiguity; measured telemetry has an independent increasing sequence for each arm.

A `target_intent` contains seven B1-bounded positions, a 0.65–10 second duration,
the granted authority UUID, and `dead_man_held=true`. It has a 50–1500 ms lease;
the Vision operator paths use 1000 ms and additionally limit each measured-relative
segment to 0.08 radian and 0.20 radian/second. The on-screen lane for each arm can
run independently. With two PSVR Sense controllers, the left and right vertical
thumbsticks can simultaneously produce one target for each matching arm after both
per-arm freshness, position-mode, authority, and in-flight gates pass.
`target_disposition` reports
accepted/executing/measured-complete progress or a terminal cancellation,
lease-expiry hold, hold confirmation failure, execution failure, or rejection.
Only `accepted_for_execution`, `executing`, and `completed_measured` are execution
eligible.

A `hold_intent` is likewise identity/session/sequence bound, has a 50–1500 ms
lease, and carries a bounded reason plus an optional authority UUID. Paired
controller jogging requires both grip buttons. Releasing either grip sends ordinary
holds for both arms while retaining the independent authorities; a deliberate fresh
two-grip hold is required to resume. Controller disconnect or input silence beyond
250 ms, stale measured feedback, position-mode/preflight loss, target timeout or
send failure, scene loss, stop, disarm, or software E-stop priority-holds and locally
disarms both arms. All message types reject unknown fields, malformed values,
oversized payloads, stale leases where
applicable, and mismatched protocol/schema values. The calibrated B1 limits are J1
±2.4435, J2 ±2.3213, J3–J6 ±2.2863, and J7 ±3.05 radians.

The Vision app never activates Amber hardware or changes actuator modes, and the
simulator advertises no physical arm execution. Cerebro and the gateway own the
final authority, measured completion, watchdog, hold-on-expiry, and physical
execution boundaries. PSVR pose IK is not transported by this workflow.
The paired controller mapper consumes normalized vertical stick values and current
measured joint vectors only. Tracked controller transforms do not become Cartesian
end-effector targets and are not used for IK puppeteering.

`supportsArmControlExecution` is currently selected by the local Cerebro transport
profile after authenticated connection; Cerebro does not negotiate that bit on the
wire. A peer without the v2 subprotocol still cannot grant authority or satisfy the
feedback and mode gates, so target transmission remains unavailable. The simulator
sets the profile false.

## Controller-supervised robot actions

Robot action approval uses the existing authenticated ROBControl application-data
channel. `CerebroRobotTransport` wraps the strict JSON message in the established
`ROBRobotActionProtocol.v1` keyed-archive envelope and verifies that the outer sender
matches the installed controller credential. Incoming requests and statuses are
accepted only when their `recipient_id` is that exact controller.

The message kinds are `controller_hello`, `action_request`, `action_status`, and
`action_cancel`. Approval defaults off. While enabled, `RobotSession` refreshes a
hello every second with the bounded capabilities `look_at`, `play_gesture`,
`request_pick`, `navigate_relative`, and `stop_motion`; disabling, backgrounding,
software E-stop, or disconnect sends withdrawal/cancellation where the connection is
still usable. Requests may live for at most 120 seconds and only one is pending.

Argument schemas are exact: look/pick take one bounded `target_id`; gesture takes one
bounded catalog `gesture` name; relative navigation takes only `distance_m` in
−1...1, `yaw_rad` in −π...π, and `speed_scale` in 0...0.35; stop takes no arguments.
Unknown or model-supplied joint keys are rejected. Operator acceptance is not
completion. For `play_gesture`, Cerebro sends `executing` and only later
`completed` after gateway acknowledgement and fresh measured settling; rejection,
timeout, cancellation, authority loss, or failure holds only the arms reserved by
that gesture run. Explicit stop and shutdown paths use the global priority hold.
Other approved actions remain manually supervised and require an explicit
completed/failed status from the operator console.

# Cerebro video integration

ROBControllerVision implements the controller side of Cerebro's initial Vision Pro video contract. The synthetic path remains a deterministic test endpoint; selecting **Cerebro** uses the authenticated network path and the same decoder surface.

## Physical transport boundary

```text
_robctl._udp / robctl/2        pairing proof, robot control, live-session authority
_robvideo._udp / robvideo/1    video proof, capabilities, subscription, feedback, media
```

Both connections use QUIC with TLS 1.3 and pin the exact Cerebro leaf fingerprint in the installed enrollment credential. They use the same controller UUID and 256-bit pairing secret, but the `robvideo/1` challenge/proof has a video-specific transcript domain so a proof cannot be replayed on the control service.

Video is not tunneled through the robot-control connection. Capabilities, subscribe/response, feedback, unsubscribe, codec configuration, access units, and stream-ended messages all use `_robvideo._udp`. A stalled or failed video stream must not delay motion, dead-man, or stop traffic on `_robctl._udp`.

## Pair and view the camera

1. Start Cerebro and verify that its selected camera is available.
2. In Cerebro, open **Manage Paired Devices…**, choose **Pair ROBController**, and name the credential **Apple Vision Pro**.
3. Create a new credential for Vision Pro. Never reuse a credential installed on ROBController or another Vision device.
4. In ROBControllerVision, select **Pair Cerebro**, paste the complete `ROBCTL2:...` code, and select **Install pairing code**. The UI now says **Credential installed**; this confirms Keychain persistence, not network authentication.
5. Allow Local Network access when visionOS asks. Keep the Vision Pro and Cerebro Mac on the same LAN.
6. Choose the **Cerebro** endpoint and select **Connect Cerebro**.
7. After control authentication, the pairing UI says **Connected and verified**. If the handshake contains a camera, select **Subscribe** in the Robot Camera panel. If it contains none, repair the optional video service and reconnect to refresh capabilities.

The app discovers only the `robot_id` named by the installed credential, verifies the pinned certificate, completes reciprocal control authentication, and retains Cerebro's exact live control-session UUID. It then makes a bounded attempt to authenticate the separate video service and receive its one-time camera capabilities. Video failure produces an otherwise ready control handshake with no cameras. When video succeeds, an H.264 `reliableStream` subscription carries the exact control UUID.

### Canonical-certificate migration

Cerebro's canonical-identity fix prevents repeated server startup or pairing-panel access from creating duplicate certificates. Its first upgraded launch can intentionally create one replacement canonical leaf from the existing private key. A controller enrolled before that migration pins the old leaf and cannot authenticate afterward.

For that one-time migration, revoke the stale Vision device in Cerebro, issue a fresh **Pair ROBController** code, and install it in ROBControllerVision. Installation replaces the app's one local Keychain profile; it does not generate Cerebro identities or duplicate certificate records. Never bypass the failure by weakening TLS verification. After migration, a changing certificate fingerprint across normal Cerebro restarts is an identity-store problem, not a reason to auto-accept a new certificate.

## Session binding

The video connection is authenticated, but authentication alone does not authorize camera delivery:

1. Cerebro creates a fresh 16-byte session ID during the authenticated `robctl/2` challenge.
2. `CerebroRobotTransport` publishes that exact UUID as the `RobotSession` handshake ID.
3. Every video subscribe, feedback, and unsubscribe message carries that UUID.
4. Cerebro verifies that the UUID is the current live control session for the video connection's authenticated controller UUID and that the credential has the `operatorController` role.
5. Replacing or closing control immediately invalidates the bound video stream.

The adapter must never generate a separate UUID for the production handshake or reuse a previous connection's UUID. A stale session is an authorization failure even when the certificate and pairing secret are otherwise valid.

## Component mapping

| Vision component | Cerebro integration responsibility |
| --- | --- |
| `ROBCerebroPairingStore` | Decode an operator `ROBCTL2:` code and keep one device-only Keychain profile. |
| Control discovery/client | Browse `_robctl._udp`, filter `robot_id`/version/ALPN, pin TLS, complete `robctl/2` proof, and expose Cerebro's session UUID. |
| `CerebroRobotTransport` | Present one `RobotTransport`/`RobotVideoDataTransport` boundary, route operations to the correct physical connection, and translate the established controller application payload privately. |
| `ROBVideoDiscovery` / `ROBVideoClient` | Browse `_robvideo._udp`; match the same robot plus `ver=1`, `alpn=robvideo/1`, `codec=h264`, and `delivery=reliableStream`; pin the same leaf; complete the video proof; receive capabilities; and exchange subscription control plus media. |
| `ROBVideoBinaryDecoder` | Validate `RVID`/`RBVD` bounds and convert complete configuration/access-unit messages into `VideoDataMessage`. |
| `VideoStreamValidator` | Enforce session, stream, codec, generation, ordering, dimensions, and AVCC invariants. |
| `H264VideoReceiver` | Create sample buffers and drive `AVSampleBufferVideoRenderer`. |
| `SyntheticPixelBufferSource` | Remain available only for the selected Simulator endpoint and deterministic tests. |

The production request asks for camera `front`, H.264, a maximum 960 x 540 frame, 20 fps, 1,500,000 bit/s, and `reliableStream`. The accepted descriptor is authoritative because Cerebro may clamp the request.

## Wire framing and receiver contract

Negotiation messages are bounded JSON inside ordered `RVID` frames on `robvideo/1`. Encoded media is binary:

```text
32-byte RVID ordered-stream frame
    └── 92-byte RBVD media header
            ├── raw SPS/PPS parameter-set records, or
            └── one complete AVCC H.264 access unit
```

The receiver enforces the current 64 KiB codec-configuration and 2 MiB access-unit limits before decoder allocation. UUIDs in `RBVD` are raw RFC 4122 bytes; the session and subscription IDs must match the active negotiated stream. Integer fields are big-endian. H.264 access units are AVCC length-prefixed NAL units, never Annex-B start-code streams.

`reliableStream` does not require application datagram fragmentation. QUIC and Network.framework segment and reassemble stream bytes below the `RVID` framer, which delivers one complete bounded application message. The old synthetic-integration note about implementing QUIC datagram fragmentation does not apply to this production profile.

Codec configuration must precede the first IDR for a generation. After a sequence gap or decoder flush, the Vision receiver suppresses predictive frames and sends bounded feedback with `requestsKeyFrame = true`. Cerebro then emits configuration followed by a recovery IDR.

## Lifecycle and backpressure

- Cerebro starts remote camera demand only after accepting a subscription and stops it when the final demand ends.
- ROBControllerVision opens the media channel only for the accepted stream and gives every open a unique ownership token.
- Scene suspension, explicit unsubscribe, disconnect, credential revocation, control-session replacement, stream-ended notification, or a fatal media validation error tears down the receiver.
- Video discovery/authentication failure is nonfatal to control. Runtime video loss ends active streams but leaves `_robctl._udp` authenticated and motion safety operational.
- Camera capabilities are captured once while connecting. Video is not hot-reconnected in the current session; disconnect and reconnect after restoring `_robvideo._udp` or the camera.
- Cleanup is identity-checked so delayed work from an old connection cannot close a replacement stream.
- Media never enters `RobotEvent` or the snapshot update stream at frame rate; only throttled receiver statistics reach SwiftUI.
- Normal media pressure drops frames and requests recovery instead of blocking the independent control path.

## Diagnostics

Browse for both services from a Mac on the same LAN. Each command continues running until interrupted:

```bash
dns-sd -B _robctl._udp local.
dns-sd -B _robvideo._udp local.
```

Expected Cerebro readiness messages identify `_robctl._udp` with QUIC/TLS and `_robvideo._udp` with QUIC/TLS plus `robvideo/1`.

| Symptom | Check |
| --- | --- |
| Neither service is discovered | Same LAN, visionOS Local Network permission, Cerebro running, multicast/Bonjour availability, and host firewall. |
| Control discovery times out | The installed code's `robot_id` must match the service TXT record with `ver=2` and `alpn=robctl/2`. |
| `_robctl._udp` appears but `_robvideo._udp` does not | Control can still connect. The handshake has no cameras, so repair the optional video service and reconnect before subscribing. |
| `_robvideo._udp` is visible to `dns-sd`, but the app ignores it | Its TXT record must match the paired `robot_id` and advertise `ver=1`, `alpn=robvideo/1`, `codec=h264`, and `delivery=reliableStream`. |
| TLS or reciprocal proof fails after the Cerebro upgrade | Revoke the stale entry and install a code issued after canonical-certificate migration. Do not accept a mismatched pin. |
| One controller connects and the other is rejected | Confirm that Vision Pro and ROBController have different Cerebro-issued controller UUIDs and secrets. |
| Control connects but no camera is advertised | Verify `_robvideo._udp`, its certificate/proof, Cerebro's camera permission, selected input, and camera state; then reconnect so the one-time capabilities are refreshed. |
| Subscription is rejected as unauthorized or stale | Disconnect and reconnect control before subscribing; confirm the adapter uses Cerebro's current session UUID. |
| Subscription is rejected for delivery or codec | Use H.264 `reliableStream`; Cerebro does not advertise QUIC datagrams, HEVC, or JPEG in this profile. |
| Video starts and then goes black | Inspect the pipeline status and drop counters; a sequence gap should trigger an IDR request. A terminal video failure ends the stream but leaves control connected; restore the service and reconnect the endpoint to obtain cameras again. |

## Safety ordering

Real video must not weaken the control safety contract. Motion retains its short input lease, scene inactivity invalidates operator intent, Cerebro enforces the definitive receive-side watchdog, and the independently wired physical emergency stop remains authoritative. Video authorization depends on control; control safety never depends on video availability.

## Initial limitations

- H.264 ordered reliable streaming only; no HEVC, JPEG-frame, or QUIC-datagram delivery.
- One monoscopic camera; no depth, stereo, spatial-video, or audio track.
- Live viewing only; no recording or replay.
- Cerebro currently permits at most two authenticated video controllers and one stream per connection.
- Reliable video can suffer head-of-line delay after packet loss, but its independent connection prevents that delay from entering robot control.

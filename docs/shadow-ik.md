# Mac shadow IK preview

Shadow IK now supports **both controllers**: left grip → ROB-left **R-11**, right
grip → ROB-right **L-10**. It also displays Mac markerless depth observations and
swept rigid-scan clearance. All output stays virtual; no actuator authority or
motor command is acquired or generated.

Build both updated apps, run Cerebro's `Scripts/setup-shadow-planner.sh`, pair the
headset with Cerebro, and open **Shadow IK** with drive and arms disarmed. Leave
**Require live vision** on for camera-referenced preview. Select each arm in turn,
point its controller approximately level in the desired ROB-forward direction,
and choose **Align controller forward**. Release, then hold each matching grip.
Both hands can operate together, with independent origins and release latches.
Release a grip to reposition that hand. Precision scales translation by 0.2; XYZ
buttons move the selected arm by 2 mm or 10 mm. Base, torso and neck stay held.

Grey is the scan reference, cyan the IK ghost, green freshly observed arm geometry,
and orange the target. Vision and clearance status appear below the model. The
view remains a kinematic proxy, not a photorealistic articulated mesh. A displayed
model target residual is not a measurement of physical accuracy.

Live mode needs fresh, observable markerless depth fits for **both** arms. It does
not require printed markers. Missing/occluded/ambiguous joints, stale depth and
unregistered cameras hold the preview. A corrected physical pose rebases the ghost
and requires release/re-clutch. Camera registration needs visible base and torso
surfaces; a camera that only sees the surroundings or grippers cannot supply that
registration. A suitable external RGB-D view may be needed. This has not yet been
validated against live ROB camera data.

To choose scan-only rehearsal, close/reopen the sheet and turn Require live vision
off before loading. Collision and centered travel checks still apply. The current
scan envelopes overlap at the torso and upper arms and **block movement pending
geometry review**. Right J2's scan estimate is +120.417° and also needs an in-range
visual correction before right-arm motion. Neither issue is silently bypassed.
The rigid model check does not certify cable travel, payloads or surroundings.

`rob-shadow-ik/2` is carried over the existing authenticated Cerebro transport. It
adds an explicit arm, independent tracked input lanes, read-only observation refresh,
and separate observed versus proposed frames. Old protocol versions cannot fall
through into physical-control parsing. The protocol source remains byte-identical
to Cerebro's copy. Late/wrong-arm replies are ignored. Tracking loss requires a real
grip release; origin changes require re-alignment. Scene suspension or live control
authority ends the preview. An old Mac build or missing runtime produces an explicit
unavailable/timeout state without a physical-control fallback.

Run:

```sh
swift test --package-path Packages/ROBControlCore
Scripts/test-shadow-preview-model.sh
xcodebuild -project ROBControllerVision.xcodeproj -scheme ROBControllerVision \
  -configuration Debug -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

For a DEBUG simulator smoke test, place an actual Mac `rob-shadow-ik/2` response in
Documents as `shadow-preview-replay.json` and launch with
`--shadow-preview-smoke-test`. It is labelled a recorded replay and never connects
to ROB. Live camera and physical controller verification still require the updated
Mac app and a reachable headset. These changes are development builds, not a store
or production companion release.

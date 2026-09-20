# Mac shadow IK preview

The control deck's **Shadow IK** button opens a three-dimensional kinematic preview
of ROB-left / R-11. Connect to the updated Cerebro with drive and arm authorities
disarmed. Choose **Load scan reference**, point the left controller forward and
choose **Align controller forward**. Release, then hold the left grip to move the
ghost gripper. Release to hold and reposition your hand. Wrist rotation requests
tool orientation; precision scales translation by 0.2 on each new clutch. XYZ
buttons provide 2 mm or 10 mm steps without a tracked controller.

Grey is the approved **scan estimate**, cyan is the Mac IK result, and orange is the
requested target. This milestone renders a kinematic proxy, not an articulated
photorealistic scan. The base, torso, neck and right arm remain fixed. No motion
authority is acquired and no motor target, gripper command or physical gesture is
produced by this protocol. Trigger-based virtual grasping and recording are not
implemented in this first milestone.

The updated Cerebro needs its isolated Drake runtime. Run its
`Scripts/setup-shadow-planner.sh` on the Mac before using the preview. An old Cerebro
build or missing runtime is reported as an unavailable/timed-out preview, with no
fallback to physical arm control. The separate simulator endpoint does not pretend
to provide Mac Drake; use a real paired Mac for interactive shadow IK.

`ROBShadowPlanningProtocol.swift` in ROBControlCore is byte-identical to Cerebro's
copy. `CerebroRobotTransport` carries it over the existing authenticated QUIC
connection. Session, preview, request and sequence identities isolate replies.
ARKit source age, tracking quality and origin identity travel with each controller
pose. `ROBShadowClutchGate` requires an actual grip release after tracking or input
loss. `ROBShadowPreviewModel` drops late replies and sends a terminating message
even when the sheet closes during worker startup. Scene loss releases the preview.

This alignment defines virtual ROB axes; it is not real-world camera registration.
There is no live visual joint estimator or collision/cable certification in this
milestone. Both the protocol and UI say that the seed is a scan estimate and that
clearance is unverified. The ±120° bounds are provisional model limits. R-11 is the
only active chain; the right J2 reference exceeds +120° and remains untouched.

Run:

```sh
swift test --package-path Packages/ROBControlCore
Scripts/test-shadow-preview-model.sh
xcodebuild -project ROBControllerVision.xcodeproj -scheme ROBControllerVision \
  -configuration Debug -destination 'generic/platform=visionOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

For a DEBUG-only visual smoke test, place an actual Mac `rob-shadow-ik/1` response
in the simulator app's Documents directory as `shadow-preview-replay.json` and
launch with `--shadow-preview-smoke-test`. This is explicitly labelled recorded
replay and does not connect to a robot. Physical controller/headset validation still
requires a reachable Vision Pro and the updated Mac app.

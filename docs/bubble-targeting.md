# Right-shoulder bubble targeting

Open **Cerebro → Servos → Bubble Targeting…** for calibration and local diagnostics.
Open **ROBController → administrator workspace → Bubbles**, or the **Bubbles** toolbar button in
ROBControllerVision, for the camera, authorization, aiming, and motor controls.

## Confirmed wiring

The operator confirmed this mapping on September 15, 2026. Historical arm names are retained in
Interface Builder; they do not describe the accessories now attached to those outputs.

| Function | Historical IBOutlet | Maestro channel | Rest / OFF |
| --- | --- | --- | --- |
| Tilt | `arm_R_Shoulder_Pan` | 6 | 8000 |
| Pan | `arm_R_Shoulder_Tilt` | 7 | 4000 |
| Fan / Red | `arm_R_Elbow_Tilt` | 8 | 4000 |
| Bubbles / Blue | `arm_R_Wrist_Pan` | 9 | 4000 |

Channel 5 (`arm_R_Elbow_Pan`) is not part of this machine. The legacy rendering timer cannot write
channels 6–9; its sliders and checkboxes now enter the bubble controller. Relay channels bypass servo
speed/acceleration smoothing so the programmed pulse widths switch immediately. The external relay
still takes approximately 0.5 seconds to respond.

The ON defaults of 8000 are **unverified candidates**, not measured relay thresholds. New activation
and aim commands start in dry run on every launch. The runtime never restores authorization or live
output mode from disk. On Maestro connection, it applies the confirmed relay OFF values and the
existing startup tuck: Tilt 8000, then Pan 4000 after 0.75 seconds.

## Operation

1. Open a controller's Bubbles panel. Its dedicated preview updates about twice per second and uses
   the main RGB-D camera independently of Cerebro's visible camera window.
2. Press **Authorize bubbles**. Only the authenticated controller session that authorizes the machine
   can activate it. Cerebro can use that authorization for its local diagnostics, but cannot grant it.
3. Tap the desired point in the camera. Vision Pro offers an 11 × 7 grid of native gaze targets: look at
   a cell and pinch. The crosshair represents the selected cell center. The manual sliders offer finer
   adjustment. Eye focus alone never activates a motor.
4. **Start fan** and **Start bubbles** are separate. Bubbles are rejected until the spin command has
   settled for 0.5 seconds. Turning off the fan also turns off bubbles.
5. **Pulse** uses a 0.5-second spin lead, 3 seconds of blower command, then 5 seconds with both off.
   **Continuous** runs until the working budget ends. Neither mode restarts after cooldown.
6. **STOP** disarms and sends both relay OFF values. **Stow laser** stops first, tucks Tilt down, then
   rotates Pan to the saved side. Authorization is inhibited during the stow sequence.

On Vision Pro, enable **Use controller X / Y for fan / bubbles** while this panel is open. X toggles
the fan and Y toggles bubbles; these face buttons do not replace the existing grip dead-man or gripper
triggers. A held button cannot activate the machine merely by enabling the option. The OS must expose
X/Y through the controller's physical input profile; hardware mapping still needs a device check.

## Servo release versus removing power

**Release Tilt/Pan** sends target 0 to channels 6 and 7. Unchecking either mount checkbox invokes the
same release and stops the bubble session. This explicit OFF action remains available in dry run.
Releasing pulses does not cut the servo power rail; loss-of-signal behavior depends on the servo.
Removing supply voltage requires a separate power-switching circuit. Fan/bubble OFF remains 4000,
never target 0. See [Pololu's Set Target protocol](https://www.pololu.com/docs/0J40/5.e) and
[power connections](https://www.pololu.com/docs/0J40/7.a).

## Duty cycle and authorization

Cerebro counts cumulative time with either motor commanded on, plus relay release tails. Brief stops,
mode changes, disarming, and reauthorization do not reset the budget. It reserves 0.6 seconds inside
the manual's 120-second limit for relay release and scheduler margin. After exhaustion it locks
activation until both outputs have been off for a full 60 seconds. Enabling live outputs imposes an
initial 60-second cooldown, which also prevents a process restart from bypassing a previous run.

Controllers send a heartbeat every 0.5 seconds. A lease expires after 2 seconds; late heartbeats cannot
revive it. Session disconnect, app backgrounding, panel closure, or STOP disarms. An independent
OFF-only watchdog can stop the relays even if Cerebro's main/UI queue stalls. A stopped or crashed
process cannot run software: configure and physically verify a Maestro serial timeout/error pose
and the relay board's loss-of-signal behavior before relying on unattended operation.

The `ROBBUBBLE1` envelope travels only over authenticated `robctl/2` operator sessions. Device and
session IDs, message direction, bounded fields, timestamps, and monotonically increasing sequence
numbers are checked. Any authenticated operator may STOP. Camera frames and status are returned
only to the requesting authenticated session, never broadcast through the compatibility transport.

## Depth calibration

The client sends a frame UUID and normalized RGB pixel; it cannot supply distance. Cerebro retains
the exact aligned depth and intrinsics for that preview, rejects frames older than two seconds,
samples a 5 × 5 depth neighborhood, and rejects holes, mixed-depth edges, out-of-range distances,
and targets outside servo travel. A pinhole projection yields the point in camera coordinates;
translation to the shoulder origin and a measured rotation produce mount yaw/elevation and servo
targets. This is geometric pointing, not a prediction of bubble flight in air currents.

Use the calibration editor in Cerebro to enter:

- Confirmed relay ON values; OFF is fixed to the operator-confirmed 4000. Set `wiringConfirmed` only
  after testing them. Save before enabling live outputs.
- Measured pan/tilt neutral pulse widths and signed units per degree.
- Mount origin relative to the camera optical frame in meters: X right, Y down, Z forward.
- Camera-to-mount rotation in degrees, applied in roll → pitch → yaw order.
- The camera neck reference, captured using **Capture neck pose**. Set `geometryConfirmed` only
  after measuring the transform at that pose and checking projected targets.

The initial zero offset/rotation and generic servo scale are explicitly uncalibrated simulation
values. Live depth aiming requires confirmed geometry and the saved neck command pose both at frame
capture and command application. Moving the camera away from that reference stops an active
calibrated run. No speculative moving-neck transform is substituted for a measurement. Servo position
is commanded, not encoder-verified. Calibrate direction, end stops, clearance, and settling on hardware.

## Validation

`bash Scripts/test-bubbles.sh` in Cerebro exercises the production duty-cycle policy, relay lead,
session ownership, sequence replay rejection, disconnect, frame identity, synthetic RGB-D projection,
dry-run output isolation, pulse release, and the watchdog with the main loop blocked. Serial I/O is
replaced by a fake object in these fixtures. Full macOS, iOS Simulator, and visionOS Simulator builds
cover the three app integrations. Wire definitions and the shared console view are copied identically
across the repositories and should remain synchronized.

No physical relay threshold, nozzle alignment, laser clearance, controller button mapping, or real
cooling performance has been verified by these software tests.

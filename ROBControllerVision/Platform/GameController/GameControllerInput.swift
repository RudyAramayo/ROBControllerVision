import ARKit
import Foundation
@preconcurrency import GameController
import Observation
import ROBControlCore
import simd

struct GameControllerSample: Equatable, Sendable {
    var isConnected: Bool
    var leftTread: Float
    var rightTread: Float
    var cameraPan: Float
    var cameraTilt: Float
    var controllerPoses: ControllerPosePair?
    var deadManIsHeld: Bool
    var leftGripperClosed: Bool
    var rightGripperClosed: Bool

    static let disconnected = GameControllerSample(
        isConnected: false,
        leftTread: 0,
        rightTread: 0,
        cameraPan: 0,
        cameraTilt: 0,
        controllerPoses: nil,
        deadManIsHeld: false,
        leftGripperClosed: false,
        rightGripperClosed: false
    )
}

@MainActor
@Observable
final class GameControllerInput: NSObject {
    private enum TreadSide {
        case left
        case right
        case both
    }

    private struct ControllerState {
        var side: TreadSide
        var lastEventTimestamp: TimeInterval = 0
        var stickY: Float = 0
        var secondStickY: Float = 0
        var cameraPan: Float = 0
        var cameraTilt: Float = 0
        var pose: ControllerPose?
        var deadManIsHeld = false
        var triggerPressed = false
    }

    private(set) var isConnected = false
    private(set) var controllerName = "No game controller"
    private(set) var deadManIsHeld = false
    private(set) var leftTread: Float = 0
    private(set) var rightTread: Float = 0
    private(set) var leftGripperClosed = false
    private(set) var rightGripperClosed = false
    private(set) var poseTrackingStatus = "Spatial pose tracking has not started"
    private(set) var lastEventDescription = "Hold both VR grip buttons to enable control"

    @ObservationIgnored var onSample: ((GameControllerSample) -> Void)?
    @ObservationIgnored private var controllers: [ObjectIdentifier: GCController] = [:]
    @ObservationIgnored private var controllerStates: [ObjectIdentifier: ControllerState] = [:]
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var physicalInputTask: Task<Void, Never>?
    @ObservationIgnored private var poseTracker: AnyObject?

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )

        for controller in GCController.controllers() {
            configure(controller)
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        GCController.stopWirelessControllerDiscovery()
        physicalInputTask?.cancel()
        physicalInputTask = nil
        for controller in controllers.values {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.physicalInputProfile.valueDidChangeHandler = nil
        }
        controllers.removeAll()
        controllerStates.removeAll()
        if #available(visionOS 26.0, *), let tracker = poseTracker as? ControllerPoseTracker {
            tracker.stop()
        }
        poseTracker = nil
        poseTrackingStatus = "Spatial pose tracking stopped"
        apply(.disconnected)
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        configure(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        let id = ObjectIdentifier(controller)
        guard controllers[id] != nil else { return }
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.physicalInputProfile.valueDidChangeHandler = nil
        controllers.removeValue(forKey: id)
        controllerStates.removeValue(forKey: id)
        reconfigurePoseTracking()
        publishCombinedSample()
    }

    private func configure(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard controllers[id] == nil else { return }
        let physicalProfile = controller.physicalInputProfile
        guard controller.extendedGamepad != nil || Self.primaryStick(in: physicalProfile) != nil else {
            if controllers.isEmpty {
                controllerName = "Unsupported controller profile"
                isConnected = false
            }
            return
        }

        let side = controller.extendedGamepad == nil ? availableSenseSide() : .both
        controllers[id] = controller
        controllerStates[id] = ControllerState(
            side: side,
            lastEventTimestamp: physicalProfile.lastEventTimestamp
        )
        assignPlayerIndices()
        updateControllerName()

        if let gamepad = controller.extendedGamepad {
            gamepad.valueChangedHandler = { [weak self] gamepad, _ in
                Task { @MainActor [weak self] in
                    self?.updateController(id, from: gamepad)
                }
            }
        } else {
            physicalProfile.valueDidChangeHandler = { [weak self] profile, _ in
                Task { @MainActor [weak self] in
                    self?.updateController(id, from: profile)
                }
            }
        }

        updateController(id, from: controller, allowDeadMan: false)
        reconfigurePoseTracking()
        startPhysicalInputPolling()
    }

    private func startPhysicalInputPolling() {
        physicalInputTask?.cancel()
        physicalInputTask = Task { @MainActor [weak self] in
            let timer = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await timer.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                self?.pollPhysicalInput()
            }
        }
    }

    private func pollPhysicalInput() {
        for (id, controller) in controllers {
            let eventTimestamp = controller.physicalInputProfile.lastEventTimestamp
            guard var state = controllerStates[id], eventTimestamp > state.lastEventTimestamp else {
                continue
            }
            state.lastEventTimestamp = eventTimestamp
            controllerStates[id] = state
            updateController(id, from: controller)
        }
    }

    private func updateController(
        _ id: ObjectIdentifier,
        from controller: GCController,
        allowDeadMan: Bool = true
    ) {
        if let gamepad = controller.extendedGamepad {
            updateController(id, from: gamepad, allowDeadMan: allowDeadMan)
        } else {
            updateController(id, from: controller.physicalInputProfile, allowDeadMan: allowDeadMan)
        }
    }

    private func updateController(
        _ id: ObjectIdentifier,
        from gamepad: GCExtendedGamepad,
        allowDeadMan: Bool = true
    ) {
        guard var state = controllerStates[id] else { return }
        // A conventional gamepad keeps ROBController's tank-drive convention: the vertical axis
        // of each thumbstick controls the corresponding tread.
        state.side = .both
        state.stickY = gamepad.leftThumbstick.yAxis.value
        state.secondStickY = gamepad.rightThumbstick.yAxis.value
        state.cameraPan = gamepad.rightThumbstick.xAxis.value
        state.cameraTilt = gamepad.rightThumbstick.yAxis.value
        // Index triggers are reserved for the two grippers. A conventional
        // gamepad uses A or both shoulder buttons as the continuous safety hold.
        state.deadManIsHeld = allowDeadMan && (
            gamepad.buttonA.isPressed
            || (gamepad.leftShoulder.isPressed && gamepad.rightShoulder.isPressed)
        )
        controllerStates[id] = state
        publishCombinedSample()
    }

    /// PSVR Sense controllers are exposed by visionOS as a physical input profile rather than a
    /// `GCExtendedGamepad`. The singular names are used by one-handed spatial controllers on
    /// visionOS 26; the left/right names preserve compatibility with earlier controller mappings.
    private func updateController(
        _ id: ObjectIdentifier,
        from profile: GCPhysicalInputProfile,
        allowDeadMan: Bool = true
    ) {
        guard let primary = Self.primaryStick(in: profile), var state = controllerStates[id] else {
            return
        }
        state.stickY = primary.yAxis.value
        state.deadManIsHeld = allowDeadMan && Self.gripIsPressed(in: profile)
        state.triggerPressed = (
            profile.buttons["Trigger"]?.value
                ?? profile.buttons[GCInputRightTrigger]?.value
                ?? profile.buttons[GCInputLeftTrigger]?.value
                ?? 0
        ) > 0.5
        controllerStates[id] = state
        publishCombinedSample()
    }

    private func availableSenseSide() -> TreadSide {
        if !controllerStates.values.contains(where: { $0.side == .left }) { return .left }
        return .right
    }

    private func assignPlayerIndices() {
        for (index, controller) in controllers.values.enumerated() {
            switch index {
            case 0: controller.playerIndex = .index1
            case 1: controller.playerIndex = .index2
            case 2: controller.playerIndex = .index3
            case 3: controller.playerIndex = .index4
            default: controller.playerIndex = .indexUnset
            }
        }
    }

    private func publishCombinedSample() {
        var left: Float = 0
        var right: Float = 0
        var cameraPan: Float = 0
        var cameraTilt: Float = 0
        var leftGripperClosed = false
        var rightGripperClosed = false
        for state in controllerStates.values {
            switch state.side {
            case .left:
                left = state.stickY
                leftGripperClosed = state.triggerPressed
            case .right:
                right = state.stickY
                rightGripperClosed = state.triggerPressed
            case .both:
                left = state.stickY
                right = state.secondStickY
                // Conventional gamepads expose independent index triggers.
                if let gamepad = controllers.first(where: { controllerStates[$0.key]?.side == .both })?.value.extendedGamepad {
                    leftGripperClosed = gamepad.leftTrigger.value > 0.5
                    rightGripperClosed = gamepad.rightTrigger.value > 0.5
                }
            }
            cameraPan = state.cameraPan
            cameraTilt = state.cameraTilt
        }
        let conventionalDeadMan = controllerStates.values.first(where: { $0.side == .both })?.deadManIsHeld == true
        let hasLeftSpatialController = controllerStates.values.contains(where: { $0.side == .left })
        let hasRightSpatialController = controllerStates.values.contains(where: { $0.side == .right })
        let spatialDeadMan = hasLeftSpatialController && hasRightSpatialController
            && controllerStates.values.filter({ $0.side != .both }).allSatisfy(\.deadManIsHeld)
        apply(GameControllerSample(
            isConnected: !controllerStates.isEmpty,
            leftTread: left,
            rightTread: right,
            cameraPan: cameraPan,
            cameraTilt: cameraTilt,
            controllerPoses: posePair(),
            deadManIsHeld: conventionalDeadMan || spatialDeadMan,
            leftGripperClosed: leftGripperClosed,
            rightGripperClosed: rightGripperClosed
        ))
        updateControllerName()
    }

    private func posePair() -> ControllerPosePair? {
        var left: ControllerPose?
        var right: ControllerPose?
        for state in controllerStates.values {
            switch state.side {
            case .left: left = state.pose
            case .right: right = state.pose
            case .both: break
            }
        }
        let pair = ControllerPosePair(left: left, right: right)
        return pair.isEmpty ? nil : pair
    }

    private func reconfigurePoseTracking() {
        guard #available(visionOS 26.0, *), AccessoryTrackingProvider.isSupported else { return }
        let tracker: ControllerPoseTracker
        if let existing = poseTracker as? ControllerPoseTracker {
            tracker = existing
        } else {
            tracker = ControllerPoseTracker()
            tracker.onStatus = { [weak self] status in
                self?.poseTrackingStatus = status
            }
            tracker.onSideIdentified = { [weak self] id, chirality in
                self?.setSide(chirality, for: id)
            }
            tracker.onPose = { [weak self] chirality, pose in
                self?.applyTrackedPose(pose, chirality: chirality)
            }
            poseTracker = tracker
        }
        tracker.track(Array(controllers.values))
    }

    @available(visionOS 26.0, *)
    private func setSide(_ chirality: Accessory.Chirality, for id: ObjectIdentifier) {
        guard var state = controllerStates[id] else { return }
        switch chirality {
        case .left: state.side = .left
        case .right: state.side = .right
        case .unspecified: return
        @unknown default: return
        }
        controllerStates[id] = state
        publishCombinedSample()
    }

    @available(visionOS 26.0, *)
    private func applyTrackedPose(_ pose: ControllerPose?, chirality: Accessory.Chirality) {
        let side: TreadSide
        switch chirality {
        case .left: side = .left
        case .right: side = .right
        case .unspecified: return
        @unknown default: return
        }
        guard let id = controllerStates.first(where: { $0.value.side == side })?.key,
            var state = controllerStates[id]
        else { return }
        state.pose = pose
        controllerStates[id] = state
        publishCombinedSample()
    }

    private func updateControllerName() {
        guard !controllers.isEmpty else { return }
        let names = Set(controllers.values.map { $0.vendorName ?? "Game controller" })
        let name = names.sorted().joined(separator: " + ")
        controllerName = controllers.count > 1 ? "\(controllers.count) \(name)s" : name
    }

    nonisolated private static func primaryStick(
        in profile: GCPhysicalInputProfile
    ) -> GCControllerDirectionPad? {
        profile.dpads[GCInputLeftThumbstick]
            ?? profile.dpads["Thumbstick"]
            ?? profile.dpads.first(where: { $0.key != GCInputDirectionPad })?.value
    }

    nonisolated private static func gripIsPressed(in profile: GCPhysicalInputProfile) -> Bool {
        profile.buttons["Grip Button"]?.isPressed == true
            || profile.buttons["Grip"]?.isPressed == true
            || profile.buttons[GCInputButtonA]?.isPressed == true
    }

    private func apply(_ sample: GameControllerSample) {
        isConnected = sample.isConnected
        deadManIsHeld = sample.deadManIsHeld
        leftTread = sample.leftTread
        rightTread = sample.rightTread
        leftGripperClosed = sample.leftGripperClosed
        rightGripperClosed = sample.rightGripperClosed
        if !sample.isConnected {
            controllerName = "No game controller"
            lastEventDescription = "Connect a compatible controller"
        } else if sample.deadManIsHeld {
            lastEventDescription = "Dead-man held — input lease is active"
        } else {
            lastEventDescription = "Motion inhibited until dead-man is held"
        }
        onSample?(sample)
    }
}

@available(visionOS 26.0, *)
@MainActor
private final class ControllerPoseTracker {
    private struct SendableController: @unchecked Sendable {
        let value: GCController
    }

    var onPose: ((Accessory.Chirality, ControllerPose?) -> Void)?
    var onSideIdentified: ((ObjectIdentifier, Accessory.Chirality) -> Void)?
    var onStatus: ((String) -> Void)?

    private var session: ARKitSession?
    private var trackingTask: Task<Void, Never>?

    func track(_ controllers: [GCController]) {
        stop()
        guard !controllers.isEmpty else { return }
        let sendableControllers = controllers.map(SendableController.init(value:))
        onStatus?("Starting spatial tracking for \(controllers.count) controller(s)…")
        trackingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let accessories = try await Task.detached {
                    var loaded: [Accessory] = []
                    for controller in sendableControllers {
                        loaded.append(try await Accessory(device: controller.value))
                    }
                    return loaded
                }.value
                guard !Task.isCancelled else { return }
                for (controller, accessory) in zip(sendableControllers, accessories) {
                    self.onSideIdentified?(
                        ObjectIdentifier(controller.value),
                        accessory.inherentChirality
                    )
                }
                let provider = AccessoryTrackingProvider(accessories: accessories)
                let session = ARKitSession()
                self.session = session
                try await session.run([provider])
                self.onStatus?("Spatial controller poses are streaming")
                for await update in provider.anchorUpdates {
                    guard !Task.isCancelled else { return }
                    let anchor = update.anchor
                    let chirality = anchor.heldChirality ?? anchor.accessory.inherentChirality
                    guard anchor.isTracked,
                        anchor.trackingState == .positionOrientationTracked
                            || anchor.trackingState == .positionOrientationTrackedLowAccuracy
                    else {
                        self.onPose?(chirality, nil)
                        continue
                    }
                    let transform = anchor.originFromAnchorTransform
                    let position = transform.columns.3
                    let orientation = simd_quatf(transform)
                    let pose = ControllerPose(
                        x: position.x,
                        y: position.y,
                        z: position.z,
                        qx: orientation.imag.x,
                        qy: orientation.imag.y,
                        qz: orientation.imag.z,
                        qw: orientation.real,
                        timestamp: Date().timeIntervalSince1970
                    )
                    self.onPose?(chirality, pose)
                }
            } catch {
                // Input and tread control remain usable when spatial tracking is unavailable or
                // denied. No stale pose is emitted as a valid arm target.
                for chirality in [Accessory.Chirality.left, .right] {
                    self.onPose?(chirality, nil)
                }
                self.onStatus?("Spatial tracking unavailable: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        trackingTask?.cancel()
        trackingTask = nil
        session?.stop()
        session = nil
    }
}

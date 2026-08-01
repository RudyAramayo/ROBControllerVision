import Foundation
import GameController
import Observation

struct GameControllerSample: Equatable, Sendable {
    var isConnected: Bool
    var linear: Float
    var angular: Float
    var cameraPan: Float
    var cameraTilt: Float
    var deadManIsHeld: Bool

    static let disconnected = GameControllerSample(
        isConnected: false,
        linear: 0,
        angular: 0,
        cameraPan: 0,
        cameraTilt: 0,
        deadManIsHeld: false
    )
}

@MainActor
@Observable
final class GameControllerInput: NSObject {
    private(set) var isConnected = false
    private(set) var controllerName = "No game controller"
    private(set) var deadManIsHeld = false
    private(set) var lastEventDescription = "Hold A or the right trigger to drive"

    @ObservationIgnored var onSample: ((GameControllerSample) -> Void)?
    @ObservationIgnored private var activeController: GCController?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var physicalInputTask: Task<Void, Never>?
    @ObservationIgnored private var lastPhysicalEventTimestamp: TimeInterval = 0

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

        if let controller = GCController.controllers().first {
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
        activeController?.extendedGamepad?.valueChangedHandler = nil
        activeController = nil
        apply(.disconnected)
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        configure(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController,
            controller === activeController
        else { return }

        activeController?.extendedGamepad?.valueChangedHandler = nil
        physicalInputTask?.cancel()
        physicalInputTask = nil
        activeController = nil
        apply(.disconnected)

        if let replacement = GCController.controllers().first {
            configure(replacement)
        }
    }

    private func configure(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else {
            controllerName = "Unsupported controller profile"
            isConnected = false
            return
        }

        activeController?.extendedGamepad?.valueChangedHandler = nil
        activeController = controller
        lastPhysicalEventTimestamp = controller.physicalInputProfile.lastEventTimestamp
        controllerName = controller.vendorName ?? "Game controller"
        isConnected = true
        lastEventDescription = "Hold A or the right trigger to drive"

        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            let sample = Self.sample(from: gamepad)
            Task { @MainActor [weak self] in
                self?.apply(sample)
            }
        }

        var initialSample = Self.sample(from: gamepad)
        initialSample.deadManIsHeld = false
        apply(initialSample)
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
        guard let controller = activeController,
            let gamepad = controller.extendedGamepad
        else { return }

        let eventTimestamp = controller.physicalInputProfile.lastEventTimestamp
        guard eventTimestamp > lastPhysicalEventTimestamp else { return }
        lastPhysicalEventTimestamp = eventTimestamp
        apply(Self.sample(from: gamepad))
    }

    nonisolated private static func sample(from gamepad: GCExtendedGamepad) -> GameControllerSample {
        GameControllerSample(
            isConnected: true,
            linear: gamepad.leftThumbstick.yAxis.value,
            angular: gamepad.leftThumbstick.xAxis.value,
            cameraPan: gamepad.rightThumbstick.xAxis.value,
            cameraTilt: gamepad.rightThumbstick.yAxis.value,
            deadManIsHeld: gamepad.buttonA.isPressed || gamepad.rightTrigger.value > 0.5
        )
    }

    private func apply(_ sample: GameControllerSample) {
        isConnected = sample.isConnected
        deadManIsHeld = sample.deadManIsHeld
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

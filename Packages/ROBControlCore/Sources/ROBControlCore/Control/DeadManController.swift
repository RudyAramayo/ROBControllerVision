import Foundation

public struct DeadManController: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var inputTimeout: Duration

        public init(inputTimeout: Duration = .milliseconds(250)) {
            self.inputTimeout = inputTimeout
        }
    }

    public enum Decision: Equatable, Sendable {
        case drive(MotionVector, ControllerPosePair?)
        case stop(MotionInhibitReason)
    }

    public let configuration: Configuration
    public private(set) var isArmed = false
    public private(set) var emergencyStopIsLatched = false

    private var sceneIsActive = true
    private var latestInput: OperatorControlSample?
    private var latestInputAt: ContinuousClock.Instant?
    private var forcedInhibitReason: MotionInhibitReason?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func setArmed(_ armed: Bool) {
        guard !emergencyStopIsLatched || !armed else { return }
        isArmed = armed
        if !armed {
            latestInput = nil
            latestInputAt = nil
            forcedInhibitReason = .operatorDisarmed
        } else if forcedInhibitReason == .operatorDisarmed {
            forcedInhibitReason = nil
        }
    }

    public mutating func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        if !active {
            invalidateInput(reason: .sceneInactive)
        } else if forcedInhibitReason == .sceneInactive {
            forcedInhibitReason = nil
        }
    }

    public mutating func update(
        _ sample: OperatorControlSample,
        at instant: ContinuousClock.Instant = .now
    ) {
        guard sceneIsActive else { return }
        guard latestInput.map({ sample.sequence > $0.sequence }) ?? true else { return }
        latestInput = sample
        latestInputAt = instant
        forcedInhibitReason = nil
    }

    public mutating func invalidateInput(reason: MotionInhibitReason) {
        latestInput = nil
        latestInputAt = nil
        forcedInhibitReason = reason
    }

    public mutating func emergencyStop() {
        emergencyStopIsLatched = true
        isArmed = false
        invalidateInput(reason: .emergencyStop)
    }

    public mutating func resetEmergencyStop() {
        emergencyStopIsLatched = false
        isArmed = false
        invalidateInput(reason: .operatorDisarmed)
    }

    public func evaluate(
        connectionIsReady: Bool,
        at instant: ContinuousClock.Instant = .now
    ) -> Decision {
        if emergencyStopIsLatched {
            return .stop(.emergencyStop)
        }
        guard connectionIsReady else {
            return .stop(.disconnected)
        }
        guard sceneIsActive else {
            return .stop(.sceneInactive)
        }
        guard isArmed else {
            return .stop(.operatorDisarmed)
        }
        if let forcedInhibitReason {
            return .stop(forcedInhibitReason)
        }
        guard let latestInput, let latestInputAt else {
            return .stop(.deadManReleased)
        }
        guard latestInput.deadManIsHeld else {
            return .stop(.deadManReleased)
        }
        guard latestInputAt.duration(to: instant) < configuration.inputTimeout else {
            return .stop(.inputExpired)
        }
        return .drive(latestInput.motion, latestInput.controllerPoses)
    }
}

import Foundation

/// Maps two independent controller stick inputs into small, measured-joint-space
/// Amber arm targets. This is deliberately not Cartesian spatial mapping or IK.
public struct RobotDualArmJointJogMapper: Sendable {
    public static let maximumTelemetryAgeMilliseconds = 250.0
    public static let maximumIncrementRadians = 0.08
    public static let maximumSpeedRadiansPerSecond = 0.2
    public static let segmentDurationRangeSeconds = 0.65 ... 0.80

    public struct Configuration: Equatable, Sendable {
        public let leftJointIndex: Int
        public let rightJointIndex: Int
        public let deadZone: Double
        public let segmentDurationSeconds: Double

        public init?(
            leftJointIndex: Int,
            rightJointIndex: Int,
            deadZone: Double = 0.15,
            segmentDurationSeconds: Double = 0.65
        ) {
            guard (0 ..< RobotArmTargetIntent.jointCount).contains(leftJointIndex),
                (0 ..< RobotArmTargetIntent.jointCount).contains(rightJointIndex),
                deadZone.isFinite,
                (0 ..< 1).contains(deadZone),
                segmentDurationSeconds.isFinite,
                RobotDualArmJointJogMapper.segmentDurationRangeSeconds.contains(
                    segmentDurationSeconds
                )
            else { return nil }

            self.leftJointIndex = leftJointIndex
            self.rightJointIndex = rightJointIndex
            self.deadZone = deadZone
            self.segmentDurationSeconds = segmentDurationSeconds
        }
    }

    public enum InhibitReason: Equatable, Sendable {
        case invalidStickInput
        case telemetryUnavailable(RobotArmSide)
        case telemetryStale(RobotArmSide)
        case measuredStateInvalid(RobotArmSide)
        case positionModeRequired(RobotArmSide)
    }

    public enum Decision: Equatable, Sendable {
        case targets(left: RobotArmTargetIntent?, right: RobotArmTargetIntent?)
        case inhibited(InhibitReason)
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Returns at most one target per arm. Both measured states must be fresh
    /// and in position mode so a caller can treat any inhibited result as a
    /// reason to request a paired measured hold.
    public func map(
        leftStickY: Double,
        rightStickY: Double,
        leftMeasuredState: RobotArmMeasuredState?,
        rightMeasuredState: RobotArmMeasuredState?,
        leftEffectiveSampleAgeMilliseconds: Double?,
        rightEffectiveSampleAgeMilliseconds: Double?
    ) -> Decision {
        guard Self.validStick(leftStickY), Self.validStick(rightStickY) else {
            return .inhibited(.invalidStickInput)
        }

        if let reason = validate(
            measuredState: leftMeasuredState,
            effectiveSampleAgeMilliseconds: leftEffectiveSampleAgeMilliseconds,
            expectedArm: .left
        ) {
            return .inhibited(reason)
        }
        if let reason = validate(
            measuredState: rightMeasuredState,
            effectiveSampleAgeMilliseconds: rightEffectiveSampleAgeMilliseconds,
            expectedArm: .right
        ) {
            return .inhibited(reason)
        }

        guard let leftMeasuredState, let rightMeasuredState else {
            // The validation above makes this unreachable, but keep target
            // construction fail-closed if that implementation ever changes.
            return .inhibited(.telemetryUnavailable(
                leftMeasuredState == nil ? .left : .right
            ))
        }

        let left = target(
            arm: .left,
            stickY: leftStickY,
            measuredPositionsRadians: leftMeasuredState.positionsRadians,
            jointIndex: configuration.leftJointIndex
        )
        let right = target(
            arm: .right,
            stickY: rightStickY,
            measuredPositionsRadians: rightMeasuredState.positionsRadians,
            jointIndex: configuration.rightJointIndex
        )
        return .targets(left: left, right: right)
    }

    private static func validStick(_ value: Double) -> Bool {
        value.isFinite && (-1 ... 1).contains(value)
    }

    private func validate(
        measuredState: RobotArmMeasuredState?,
        effectiveSampleAgeMilliseconds: Double?,
        expectedArm: RobotArmSide
    ) -> InhibitReason? {
        guard let measuredState, let effectiveSampleAgeMilliseconds else {
            return .telemetryUnavailable(expectedArm)
        }
        guard measuredState.arm == expectedArm,
            RobotArmTargetIntent.containsPositions(measuredState.positionsRadians)
        else {
            return .measuredStateInvalid(expectedArm)
        }
        let effectiveAge = max(
            measuredState.sampleAgeMilliseconds,
            effectiveSampleAgeMilliseconds
        )
        guard effectiveSampleAgeMilliseconds.isFinite,
            effectiveSampleAgeMilliseconds >= 0,
            (0 ... Self.maximumTelemetryAgeMilliseconds).contains(effectiveAge)
        else {
            return .telemetryStale(expectedArm)
        }
        guard measuredState.modes.count == RobotArmTargetIntent.jointCount,
            measuredState.modes.allSatisfy({ $0 == 2 })
        else {
            return .positionModeRequired(expectedArm)
        }
        return nil
    }

    private func target(
        arm: RobotArmSide,
        stickY: Double,
        measuredPositionsRadians: [Double],
        jointIndex: Int
    ) -> RobotArmTargetIntent? {
        let magnitude = abs(stickY)
        guard magnitude > configuration.deadZone else { return nil }

        let normalizedMagnitude = (magnitude - configuration.deadZone)
            / (1 - configuration.deadZone)
        let direction = stickY < 0 ? -1.0 : 1.0
        let maximumRateLimitedIncrement = Self.maximumSpeedRadiansPerSecond
            * configuration.segmentDurationSeconds
        let maximumIncrement = min(
            Self.maximumIncrementRadians,
            maximumRateLimitedIncrement
        )
        let requestedIncrement = direction * normalizedMagnitude * maximumIncrement
        let bounds = RobotArmTargetIntent.jointBoundsRadians[jointIndex]
        let measuredPosition = measuredPositionsRadians[jointIndex]
        let targetPosition = min(
            bounds.upperBound,
            max(bounds.lowerBound, measuredPosition + requestedIncrement)
        )
        guard targetPosition != measuredPosition else { return nil }

        var positions = measuredPositionsRadians
        positions[jointIndex] = targetPosition
        return RobotArmTargetIntent(
            arm: arm,
            source: .visionProJointUI,
            positionsRadians: positions,
            durationSeconds: configuration.segmentDurationSeconds
        )
    }
}

import Foundation
import Testing

@testable import ROBControlCore

@Suite("Dual-arm measured-joint jog mapping")
struct DualArmJointJogMapperTests {
    private let now: Int64 = 1_725_000_000_000

    @Test("Independent full-scale sticks change only the configured joints")
    func independentTargets() throws {
        let mapper = try makeMapper(leftJoint: 1, rightJoint: 5)
        let leftMeasured = try measured(arm: .left, positions: [0, 0.2, 0, 0, 0, 0, 0])
        let rightMeasured = try measured(arm: .right, positions: [0, 0, 0, 0, 0, -0.3, 0])

        guard case .targets(let left, let right) = mapper.map(
            leftStickY: 1,
            rightStickY: -1,
            leftMeasuredState: leftMeasured,
            rightMeasuredState: rightMeasured,
            leftEffectiveSampleAgeMilliseconds: 10,
            rightEffectiveSampleAgeMilliseconds: 12
        ) else {
            Issue.record("Expected two measured-joint targets")
            return
        }
        let leftTarget = try #require(left)
        let rightTarget = try #require(right)

        #expect(leftTarget.arm == .left)
        #expect(leftTarget.source == .visionProJointUI)
        #expect(leftTarget.durationSeconds == 0.65)
        #expect(leftTarget.positionsRadians[1] == 0.28)
        #expect(leftTarget.positionsRadians.enumerated().allSatisfy { index, value in
            index == 1 || value == leftMeasured.positionsRadians[index]
        })

        #expect(rightTarget.arm == .right)
        #expect(rightTarget.source == .visionProJointUI)
        #expect(rightTarget.durationSeconds == 0.65)
        #expect(rightTarget.positionsRadians[5] == -0.38)
        #expect(rightTarget.positionsRadians.enumerated().allSatisfy { index, value in
            index == 5 || value == rightMeasured.positionsRadians[index]
        })

        let leftStep = abs(leftTarget.positionsRadians[1] - leftMeasured.positionsRadians[1])
        let rightStep = abs(rightTarget.positionsRadians[5] - rightMeasured.positionsRadians[5])
        let floatingPointTolerance = 0.000_000_001
        #expect(leftStep <= RobotDualArmJointJogMapper.maximumIncrementRadians
            + floatingPointTolerance)
        #expect(rightStep <= RobotDualArmJointJogMapper.maximumIncrementRadians
            + floatingPointTolerance)
        #expect(leftStep / leftTarget.durationSeconds
            <= RobotDualArmJointJogMapper.maximumSpeedRadiansPerSecond)
        #expect(rightStep / rightTarget.durationSeconds
            <= RobotDualArmJointJogMapper.maximumSpeedRadiansPerSecond)
    }

    @Test("Dead zone is per arm and the active magnitude is rescaled")
    func deadZoneAndRescaling() throws {
        let mapper = try makeMapper(leftJoint: 0, rightJoint: 0, deadZone: 0.2)
        let leftMeasured = try measured(arm: .left)
        let rightMeasured = try measured(arm: .right)

        guard case .targets(let left, let right) = mapper.map(
            leftStickY: 0.2,
            rightStickY: 0.6,
            leftMeasuredState: leftMeasured,
            rightMeasuredState: rightMeasured,
            leftEffectiveSampleAgeMilliseconds: 0,
            rightEffectiveSampleAgeMilliseconds: 0
        ) else {
            Issue.record("Expected an independent right-arm target")
            return
        }
        #expect(left == nil)
        let rightTarget = try #require(right)
        #expect(abs(rightTarget.positionsRadians[0] - 0.04) < 0.000_000_001)
    }

    @Test("Hard joint limits clamp outward motion without changing other joints")
    func hardLimitClamping() throws {
        let mapper = try makeMapper(leftJoint: 0, rightJoint: 6)
        let leftUpper = RobotArmTargetIntent.jointBoundsRadians[0].upperBound
        let rightLower = RobotArmTargetIntent.jointBoundsRadians[6].lowerBound
        let leftMeasured = try measured(
            arm: .left,
            positions: [leftUpper - 0.02, 0, 0, 0, 0, 0, 0]
        )
        let rightMeasured = try measured(
            arm: .right,
            positions: [0, 0, 0, 0, 0, 0, rightLower + 0.03]
        )

        guard case .targets(let left, let right) = mapper.map(
            leftStickY: 1,
            rightStickY: -1,
            leftMeasuredState: leftMeasured,
            rightMeasuredState: rightMeasured,
            leftEffectiveSampleAgeMilliseconds: 1,
            rightEffectiveSampleAgeMilliseconds: 1
        ) else {
            Issue.record("Expected hard-limit-clamped targets")
            return
        }
        #expect(left?.positionsRadians[0] == leftUpper)
        #expect(right?.positionsRadians[6] == rightLower)
    }

    @Test("Missing, stale, mismatched, or non-position telemetry inhibits both arms")
    func telemetryFailsClosed() throws {
        let mapper = try makeMapper(leftJoint: 0, rightJoint: 0)
        let left = try measured(arm: .left)
        let right = try measured(arm: .right)

        #expect(mapper.map(
            leftStickY: 1,
            rightStickY: 1,
            leftMeasuredState: nil,
            rightMeasuredState: right,
            leftEffectiveSampleAgeMilliseconds: nil,
            rightEffectiveSampleAgeMilliseconds: 0
        ) == .inhibited(.telemetryUnavailable(.left)))

        #expect(mapper.map(
            leftStickY: 1,
            rightStickY: 1,
            leftMeasuredState: left,
            rightMeasuredState: right,
            leftEffectiveSampleAgeMilliseconds: 251,
            rightEffectiveSampleAgeMilliseconds: 0
        ) == .inhibited(.telemetryStale(.left)))

        #expect(mapper.map(
            leftStickY: 1,
            rightStickY: 1,
            leftMeasuredState: left,
            rightMeasuredState: right,
            leftEffectiveSampleAgeMilliseconds: -1,
            rightEffectiveSampleAgeMilliseconds: 0
        ) == .inhibited(.telemetryStale(.left)))

        #expect(mapper.map(
            leftStickY: 1,
            rightStickY: 1,
            leftMeasuredState: right,
            rightMeasuredState: right,
            leftEffectiveSampleAgeMilliseconds: 0,
            rightEffectiveSampleAgeMilliseconds: 0
        ) == .inhibited(.measuredStateInvalid(.left)))

        let outsideB1Bounds = try measured(
            arm: .left,
            positions: [3, 0, 0, 0, 0, 0, 0]
        )
        #expect(mapper.map(
            leftStickY: 1,
            rightStickY: 1,
            leftMeasuredState: outsideB1Bounds,
            rightMeasuredState: right,
            leftEffectiveSampleAgeMilliseconds: 0,
            rightEffectiveSampleAgeMilliseconds: 0
        ) == .inhibited(.measuredStateInvalid(.left)))

        let nonPositionRight = try measured(
            arm: .right,
            modes: [2, 2, 2, 2, 2, 2, 0]
        )
        #expect(mapper.map(
            leftStickY: 1,
            rightStickY: 1,
            leftMeasuredState: left,
            rightMeasuredState: nonPositionRight,
            leftEffectiveSampleAgeMilliseconds: 0,
            rightEffectiveSampleAgeMilliseconds: 0
        ) == .inhibited(.positionModeRequired(.right)))
    }

    @Test("Invalid stick values and unsafe configurations fail closed")
    func invalidInputAndConfiguration() throws {
        let mapper = try makeMapper(leftJoint: 0, rightJoint: 0)
        let left = try measured(arm: .left)
        let right = try measured(arm: .right)

        for invalidStick in [Double.nan, .infinity, -1.01, 1.01] {
            #expect(mapper.map(
                leftStickY: invalidStick,
                rightStickY: 0,
                leftMeasuredState: left,
                rightMeasuredState: right,
                leftEffectiveSampleAgeMilliseconds: 0,
                rightEffectiveSampleAgeMilliseconds: 0
            ) == .inhibited(.invalidStickInput))
        }

        #expect(RobotDualArmJointJogMapper.Configuration(
            leftJointIndex: -1,
            rightJointIndex: 0
        ) == nil)
        #expect(RobotDualArmJointJogMapper.Configuration(
            leftJointIndex: 0,
            rightJointIndex: 7
        ) == nil)
        #expect(RobotDualArmJointJogMapper.Configuration(
            leftJointIndex: 0,
            rightJointIndex: 0,
            deadZone: 1
        ) == nil)
        #expect(RobotDualArmJointJogMapper.Configuration(
            leftJointIndex: 0,
            rightJointIndex: 0,
            segmentDurationSeconds: 0.64
        ) == nil)
        #expect(RobotDualArmJointJogMapper.Configuration(
            leftJointIndex: 0,
            rightJointIndex: 0,
            segmentDurationSeconds: 0.81
        ) == nil)
    }

    @Test("Reported telemetry age cannot be hidden by a newer receipt age")
    func reportedAgeIsPartOfFreshness() throws {
        let mapper = try makeMapper(leftJoint: 0, rightJoint: 0)
        let staleLeft = try measured(arm: .left, sampleAgeMilliseconds: 251)
        let right = try measured(arm: .right)

        #expect(mapper.map(
            leftStickY: 1,
            rightStickY: 1,
            leftMeasuredState: staleLeft,
            rightMeasuredState: right,
            leftEffectiveSampleAgeMilliseconds: 0,
            rightEffectiveSampleAgeMilliseconds: 0
        ) == .inhibited(.telemetryStale(.left)))
    }

    private func makeMapper(
        leftJoint: Int,
        rightJoint: Int,
        deadZone: Double = 0.15
    ) throws -> RobotDualArmJointJogMapper {
        let configuration = try #require(RobotDualArmJointJogMapper.Configuration(
            leftJointIndex: leftJoint,
            rightJointIndex: rightJoint,
            deadZone: deadZone
        ))
        return RobotDualArmJointJogMapper(configuration: configuration)
    }

    private func measured(
        arm: RobotArmSide,
        positions: [Double] = Array(repeating: 0, count: 7),
        sampleAgeMilliseconds: Double = 0,
        modes: [Int] = Array(repeating: 2, count: 7)
    ) throws -> RobotArmMeasuredState {
        try #require(RobotArmMeasuredState(
            arm: arm,
            sequence: 1,
            sampledAtUnixMilliseconds: now,
            sampleAgeMilliseconds: sampleAgeMilliseconds,
            positionsRadians: positions,
            velocitiesRadiansPerSecond: Array(repeating: 0, count: 7),
            currents: Array(repeating: 0, count: 7),
            statuses: Array(repeating: 0, count: 7),
            modes: modes
        ))
    }
}

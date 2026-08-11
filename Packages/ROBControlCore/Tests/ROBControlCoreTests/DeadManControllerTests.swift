import Testing

@testable import ROBControlCore

@Suite("Dead-man controller")
struct DeadManControllerTests {
    @Test("Motion is disarmed by default")
    func disarmedByDefault() {
        let controller = DeadManController()

        #expect(
            controller.evaluate(connectionIsReady: true) == .stop(.operatorDisarmed)
        )
    }

    @Test("Input expires exactly at the configured boundary")
    func exactTimeoutBoundary() {
        let origin = ContinuousClock.now
        var controller = DeadManController(
            configuration: .init(inputTimeout: .milliseconds(250))
        )
        controller.setArmed(true)
        controller.update(
            OperatorControlSample(
                sequence: 1,
                source: .testHarness,
                linear: 0.7,
                angular: -0.2,
                deadManIsHeld: true
            ),
            at: origin
        )

        #expect(
            controller.evaluate(
                connectionIsReady: true,
                at: origin.advanced(by: .milliseconds(249))
            ) == .drive(MotionVector(linear: 0.7, angular: -0.2), .centered, .init(isActive: true), nil)
        )
        #expect(
            controller.evaluate(
                connectionIsReady: true,
                at: origin.advanced(by: .milliseconds(250))
            ) == .stop(.inputExpired)
        )
    }

    @Test("Emergency stop remains latched until an explicit reset")
    func emergencyStopLatches() {
        var controller = DeadManController()
        controller.setArmed(true)
        controller.emergencyStop()
        controller.setArmed(true)

        #expect(controller.emergencyStopIsLatched)
        #expect(!controller.isArmed)
        #expect(controller.evaluate(connectionIsReady: true) == .stop(.emergencyStop))

        controller.resetEmergencyStop()

        #expect(!controller.emergencyStopIsLatched)
        #expect(!controller.isArmed)
        #expect(controller.evaluate(connectionIsReady: true) == .stop(.operatorDisarmed))
    }

    @Test("Inactive scenes immediately inhibit motion")
    func inactiveSceneStopsMotion() {
        let origin = ContinuousClock.now
        var controller = DeadManController()
        controller.setArmed(true)
        controller.update(
            OperatorControlSample(
                sequence: 1,
                source: .testHarness,
                linear: 1,
                angular: 0,
                deadManIsHeld: true
            ),
            at: origin
        )
        controller.setSceneActive(false)

        #expect(
            controller.evaluate(connectionIsReady: true, at: origin) == .stop(.sceneInactive)
        )
    }

    @Test("Input received in an inactive scene cannot resume motion")
    func inactiveSceneRejectsInput() {
        let origin = ContinuousClock.now
        var controller = DeadManController()
        controller.setArmed(true)
        controller.setSceneActive(false)
        controller.update(
            OperatorControlSample(
                sequence: 1,
                source: .gameController,
                linear: 1,
                angular: 0,
                deadManIsHeld: true
            ),
            at: origin
        )

        controller.setSceneActive(true)

        #expect(
            controller.evaluate(connectionIsReady: true, at: origin) == .stop(.deadManReleased)
        )
    }

    @Test("Fresh operator intent clears a recoverable input invalidation")
    func freshInputClearsInvalidation() {
        let origin = ContinuousClock.now
        var controller = DeadManController()
        controller.setArmed(true)
        controller.invalidateInput(reason: .deadManReleased)
        controller.update(
            OperatorControlSample(
                sequence: 1,
                source: .testHarness,
                linear: 0.5,
                angular: 0,
                deadManIsHeld: true
            ),
            at: origin
        )

        #expect(
            controller.evaluate(connectionIsReady: true, at: origin)
                == .drive(MotionVector(linear: 0.5, angular: 0), .centered, .init(isActive: true), nil)
        )
    }
}

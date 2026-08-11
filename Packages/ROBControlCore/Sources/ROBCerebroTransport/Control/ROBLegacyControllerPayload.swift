import Foundation
import ROBControlCore

/// Compatibility encoder for Cerebro's established ROBController application payload.
///
/// Transport authentication and framing remain v2 QUIC/TLS. Only the application payload uses
/// the historical keyed dictionary and fourteen-line controller snapshot until Cerebro and every
/// controller adopt a shared typed control message.
enum ROBLegacyControllerPayload {
    private static let maximumArchivedBytes = 64 * 1_024

    static func requestMotionAuthority(senderID: UUID) throws -> Data {
        try archive(message: "RequestToBeMasterController", senderID: senderID)
    }

    static func releaseMotionAuthority(senderID: UUID) throws -> Data {
        try archive(message: "ReleaseMasterController", senderID: senderID)
    }

    static func controllerSnapshot(
        motion: MotionVector,
        camera: CameraVector = .centered,
        grippers: GripperVector = .inactive,
        senderID: UUID,
        brakeIsLocked: Bool,
        neckControlActive: Bool = false,
        controllerPoses: ControllerPosePair? = nil
    ) throws -> Data {
        let left: Float
        let right: Float
        if brakeIsLocked {
            left = -1_000
            right = -1_000
        } else {
            // Cerebro consumes the two tread values independently as floating-point joystick
            // positions, where magnitude 0.5 is full scale. Do not normalize one tread against
            // the other: tank steering intentionally permits distinct simultaneous values.
            let rawLeft = motion.linear + motion.angular
            let rawRight = motion.linear - motion.angular
            left = max(-0.5, min(0.5, rawLeft * 0.5))
            right = max(-0.5, min(0.5, rawRight * 0.5))
        }

        let message = [
            "1.00,0.00,0.00,",
            "0.00,1.00,0.00,",
            "0.00,0.00,1.00,",
            String(format: "yaw=%.6f", locale: posixLocale, camera.pan),
            String(format: "pitch=%.6f", locale: posixLocale, camera.tilt),
            "roll=\(neckControlActive ? "1.000000" : "0.000000")",
            String(format: "touchPadL - 0.000000,%.6f", locale: posixLocale, left),
            String(format: "touchPadR - 0.000000,%.6f", locale: posixLocale, right),
            "(Lat,Long):0.000000:0.000000",
            "tredBrakeLock=\(brakeIsLocked ? 1 : 0)",
            "flipper=0,0,0,1",
            "lact=0,0,0",
            "speed=100.000000,play=0,forward-reverse=1",
            "TEXT=",
        ].joined(separator: "\n")

        return try archive(
            message: message,
            senderID: senderID,
            controllerPoses: controllerPoses,
            grippers: grippers
        )
    }

    static func stoppedSnapshot(
        senderID: UUID,
        controllerPoses: ControllerPosePair? = nil
    ) throws -> Data {
        try controllerSnapshot(
            motion: .stopped,
            senderID: senderID,
            brakeIsLocked: true,
            neckControlActive: false,
            controllerPoses: controllerPoses
        )
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func archive(
        message: String,
        senderID: UUID,
        controllerPoses: ControllerPosePair? = nil,
        grippers: GripperVector = .inactive
    ) throws -> Data {
        let envelope = NSMutableDictionary(dictionary: [
            "message": message,
            "sender": senderID.uuidString.lowercased(),
        ])
        if let controllerPoses, !controllerPoses.isEmpty {
            envelope["controller.pose.version"] = "1"
            if let left = controllerPoses.left { envelope["controller.pose.left"] = poseString(left) }
            if let right = controllerPoses.right { envelope["controller.pose.right"] = poseString(right) }
        }
        if grippers.isActive {
            envelope["gripper.control.version"] = "1"
            envelope["gripper.left.closed"] = grippers.leftClosed ? "1" : "0"
            envelope["gripper.right.closed"] = grippers.rightClosed ? "1" : "0"
        }
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: envelope,
            requiringSecureCoding: true
        )
        guard !data.isEmpty, data.count <= maximumArchivedBytes else {
            throw ROBCerebroTransportError.invalidApplicationPayload
        }
        return data
    }

    private static func poseString(_ pose: ControllerPose) -> String {
        String(
            format: "%.6f,%.6f,%.6f,%.7f,%.7f,%.7f,%.7f,%.6f",
            locale: posixLocale,
            pose.x, pose.y, pose.z, pose.qx, pose.qy, pose.qz, pose.qw, pose.timestamp
        )
    }
}

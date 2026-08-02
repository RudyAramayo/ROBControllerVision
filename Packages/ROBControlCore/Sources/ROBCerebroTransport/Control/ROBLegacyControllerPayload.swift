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
        senderID: UUID,
        brakeIsLocked: Bool
    ) throws -> Data {
        let left: Float
        let right: Float
        if brakeIsLocked {
            left = -1_000
            right = -1_000
        } else {
            // Cerebro's tread bridge treats joystick magnitude 0.5 as full scale. Normalize the
            // arcade-drive mix back to the strongest requested axis before applying that scale;
            // otherwise simultaneous drive and turn inputs can exceed the UI's speed limit.
            let rawLeft = motion.linear + motion.angular
            let rawRight = motion.linear - motion.angular
            let requestedMagnitude = max(abs(motion.linear), abs(motion.angular))
            let mixedMagnitude = max(abs(rawLeft), abs(rawRight))
            let normalization = mixedMagnitude > 0 ? requestedMagnitude / mixedMagnitude : 0
            left = max(-0.5, min(0.5, rawLeft * normalization * 0.5))
            right = max(-0.5, min(0.5, rawRight * normalization * 0.5))
        }

        let message = [
            "1.00,0.00,0.00,",
            "0.00,1.00,0.00,",
            "0.00,0.00,1.00,",
            "yaw=0.000000",
            "pitch=0.000000",
            "roll=0.000000",
            String(format: "touchPadL - 0.000000,%.6f", locale: posixLocale, left),
            String(format: "touchPadR - 0.000000,%.6f", locale: posixLocale, right),
            "(Lat,Long):0.000000:0.000000",
            "tredBrakeLock=\(brakeIsLocked ? 1 : 0)",
            "flipper=0,0,0,1",
            "lact=0,0,0",
            "speed=100.000000,play=0,forward-reverse=1",
            "TEXT=",
        ].joined(separator: "\n")

        return try archive(message: message, senderID: senderID)
    }

    static func stoppedSnapshot(senderID: UUID) throws -> Data {
        try controllerSnapshot(motion: .stopped, senderID: senderID, brakeIsLocked: true)
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func archive(message: String, senderID: UUID) throws -> Data {
        let envelope: NSDictionary = [
            "message": message,
            "sender": senderID.uuidString.lowercased(),
        ]
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: envelope,
            requiringSecureCoding: true
        )
        guard !data.isEmpty, data.count <= maximumArchivedBytes else {
            throw ROBCerebroTransportError.invalidApplicationPayload
        }
        return data
    }
}

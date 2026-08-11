import ARKit
import QuartzCore
import simd

struct HeadOrientationSample: Sendable {
    let pan: Float
    let tilt: Float
    let isTracked: Bool

    static let unavailable = HeadOrientationSample(pan: 0, tilt: 0, isTracked: false)
}

/// Converts the Vision Pro device anchor into a bounded orientation relative to
/// the pose at which the operator pressed the dead-man control.
@MainActor
final class HeadOrientationInput {
    var onSample: ((HeadOrientationSample) -> Void)?

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var pollingTask: Task<Void, Never>?
    private var deadManIsHeld = false
    private var baseline: simd_quatf?

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.run([worldTracking])
            } catch {
                onSample?(.unavailable)
                return
            }

            let clock = ContinuousClock()
            while !Task.isCancelled {
                updateFromDeviceAnchor()
                do {
                    try await clock.sleep(for: .milliseconds(40))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        deadManIsHeld = false
        baseline = nil
        session.stop()
    }

    func setDeadManHeld(_ held: Bool) {
        guard held != deadManIsHeld else { return }
        deadManIsHeld = held
        baseline = nil
        if !held { onSample?(.unavailable) }
    }

    private func updateFromDeviceAnchor() {
        guard deadManIsHeld,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked
        else {
            if deadManIsHeld { onSample?(.unavailable) }
            return
        }

        let orientation = simd_quatf(anchor.originFromAnchorTransform)
        guard let baseline else {
            self.baseline = orientation
            onSample?(HeadOrientationSample(pan: 0, tilt: 0, isTracked: true))
            return
        }

        let relative = baseline.inverse * orientation
        let forward = simd_normalize(relative.act(SIMD3<Float>(0, 0, -1)))
        let yaw = atan2(-forward.x, -forward.z)
        let pitch = asin(max(-1, min(1, forward.y)))
        let maximumYaw = Float.pi / 3       // 60 degrees maps to full pan.
        let maximumPitch = Float.pi * 35 / 180
        onSample?(HeadOrientationSample(
            pan: max(-1, min(1, yaw / maximumYaw)),
            tilt: max(-1, min(1, pitch / maximumPitch)),
            isTracked: true
        ))
    }
}

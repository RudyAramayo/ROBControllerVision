import SwiftUI
import RealityKit
import ROBControlCore

struct ROBShadowPreviewPanel: View {
    @ObservedObject var model: ROBShadowPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var scene = ROBShadowScene()
    @State private var sideView = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("ROB Shadow IK", systemImage: "cube.transparent").font(.title2.bold())
                Spacer()
                Text("PREVIEW ONLY · NO MOTOR OUTPUT").font(.caption.bold()).foregroundStyle(.cyan)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close shadow preview")
            }
            Text("Left arm R-11 • base, torso and right arm fixed")
                .font(.subheadline).foregroundStyle(.secondary)
            RealityView { content in
                content.add(scene.root)
                scene.update(model.response, sideView: sideView)
            } update: { _ in
                scene.update(model.response, sideView: sideView)
            }
            .frame(height: 355)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 20))
            HStack(spacing: 22) {
                Label("Scan estimate", systemImage: "circle.fill").foregroundStyle(.gray)
                Label("IK ghost", systemImage: "circle.fill").foregroundStyle(.cyan)
                Label("Requested target", systemImage: "scope").foregroundStyle(.orange)
                Spacer()
                Toggle("Side view", isOn: $sideView).toggleStyle(.button)
            }.font(.caption)
            Text(model.detail).font(.callout).frame(minHeight: 38, alignment: .leading)
            HStack {
                Button(model.response == nil ? "Load scan reference" : "Reset preview") { model.start() }
                    .disabled(model.waiting || model.isRecordedReplay)
                Button("Align controller forward") { model.alignForward() }.disabled(!model.canAlign)
                Toggle("Precision ×0.2", isOn: $model.precision).toggleStyle(.button)
                    .disabled(model.waiting)
                if model.waiting { ProgressView().controlSize(.small) }
            }
            Text("Point the left controller along the direction you want to mean ROB’s forward, then align. Release and hold the left grip to move the ghost. Release to reposition your hand.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(model.trackingDetail).font(.caption)
                Spacer()
                ForEach(Array(["Forward", "Left", "Up"].enumerated()), id: \.offset) { index, label in
                    VStack(spacing: 5) {
                        Text(label).font(.caption2)
                        HStack(spacing: 6) {
                            Button("−") { model.nudge(axis: index, sign: -1) }
                            Button("+") { model.nudge(axis: index, sign: 1) }
                        }.disabled(!model.canNudge)
                    }
                }
            }
            Text("XYZ steps: \(model.precision ? "2" : "10") mm • provisional ±120° arm range • clearance and cable travel unverified")
                .font(.caption2).foregroundStyle(.orange)
            if let response = model.response {
                HStack {
                    Text("Mac solve: \(response.solveMilliseconds, specifier: "%0.1f") ms")
                    if let error = response.positionErrorMeters {
                        Text("Target error: \(error * 1000, specifier: "%0.2f") mm")
                    }
                    Spacer()
                    Text("Scan reference · not live vision")
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 940)
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }
}

/// Kinematic proxy rendering: transforms come only from the Mac response. The
/// grey reference is intentionally never described as observed physical ROB.
@MainActor private final class ROBShadowScene {
    let root = Entity()
    private let robot = Entity()
    private var entities: [String: ModelEntity] = [:]
    private let ball = MeshResource.generateSphere(radius: 1)
    private let rod = MeshResource.generateCylinder(height: 1, radius: 1)
    private let box = MeshResource.generateBox(size: 1)
    init() {
        root.addChild(robot)
        root.scale = SIMD3(repeating: 0.12)
        root.position = [0, -0.07, 0]
    }
    private func position(_ pose: ROBShadowPose) -> SIMD3<Float> {
        // Proper ROB(X forward,Y left,Z up) → RealityKit(Y up) rotation.
        [Float(pose.position[1]), Float(pose.position[2]), Float(pose.position[0])]
    }
    private func entity(_ name: String, mesh: MeshResource, color: UIColor) -> ModelEntity {
        if let value = entities[name] { value.isEnabled = true; return value }
        let value = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: color, isMetallic: false)])
        robot.addChild(value); entities[name] = value; return value
    }
    private func sphere(_ name: String, at point: SIMD3<Float>, radius: Float, color: UIColor) {
        let value = entity(name, mesh: ball, color: color)
        value.position = point; value.scale = SIMD3(repeating: radius)
    }
    private func line(_ name: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, color: UIColor) {
        let length = simd_length(b - a)
        guard length > 0.00001 else { return }
        let value = entity(name, mesh: rod, color: color)
        value.position = (a + b) / 2; value.scale = [radius, length, radius]
        value.orientation = simd_quatf(from: [0, 1, 0], to: (b - a) / length)
    }
    func update(_ response: ROBShadowResponse?, sideView: Bool) {
        robot.orientation = simd_quatf(angle: sideView ? -.pi / 2 : -.pi / 9, axis: [0, 1, 0])
        for value in entities.values { value.isEnabled = false }
        // Ground and front-direction guide are useful even before connecting.
        for i in -4...4 {
            let v = Float(i) * 0.1
            line("gx\(i)", [v, 0, -0.4], [v, 0, 0.4], radius: 0.0015, color: .darkGray)
            line("gz\(i)", [-0.4, 0, v], [0.4, 0, v], radius: 0.0015, color: .darkGray)
        }
        line("forward", [0, 0.002, 0], [0, 0.002, 0.52], radius: 0.004, color: .systemOrange)
        guard let response else { return }
        let height = max(1, (response.referenceFrames + response.ghostFrames).map { $0.pose.position[2] }.max() ?? 1)
        root.scale = SIMD3(repeating: Float(0.16 / (height + 0.12)))
        for (prefix, frames, color) in [("reference", response.referenceFrames, UIColor.gray.withAlphaComponent(0.3)),
                                        ("ghost", response.ghostFrames, UIColor.cyan.withAlphaComponent(0.75))] {
            let poses = Dictionary(uniqueKeysWithValues: frames.map { ($0.name, $0.pose) })
            for side in ["left", "right"] {
                let chain = ["base_link", "one_Link", "two_Link", "three_Link", "four_Link", "five_Link", "six_Link", "seven_Link", "tool"]
                    .compactMap { poses["\(side)_\($0)"].map(position) }
                let armColor = side == "left" ? color : UIColor.gray.withAlphaComponent(0.3)
                for (i, point) in chain.enumerated() {
                    sphere("\(prefix)-\(side)-joint\(i)", at: point, radius: 0.017, color: armColor)
                    if i > 0 { line("\(prefix)-\(side)-link\(i)", chain[i - 1], point, radius: 0.011, color: armColor) }
                }
                if let tool = poses["\(side)_tool"] {
                    let value = entity("\(prefix)-\(side)-gripper", mesh: box, color: armColor)
                    value.position = position(tool); value.scale = [0.06, 0.016, 0.035]
                    let q = tool.quaternion
                    let mapping = simd_quatf(simd_float3x3(columns: (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0))))
                    value.orientation = mapping * simd_quatf(ix: Float(q[0]), iy: Float(q[1]), iz: Float(q[2]), r: Float(q[3]))
                }
            }
            if prefix == "reference" {
                for (a, b) in [("base_link", "torso_link"), ("torso_link", "lower_neck_link"),
                               ("lower_neck_link", "upper_neck_link"), ("upper_neck_link", "insta360_link")] {
                    if let pa = poses[a], let pb = poses[b] {
                        line("body-\(b)", position(pa), position(pb), radius: 0.018, color: .gray)
                    }
                }
                if let head = poses["insta360_link"] { sphere("head", at: position(head), radius: 0.09, color: .gray.withAlphaComponent(0.3)) }
                for side in ["left", "right"] {
                    let wheels = ["sprocket_link", "track_front_idler_link", "track_upper_idler_link"]
                        .compactMap { poses["\(side)_\($0)"].map(position) }
                    if wheels.count == 3 {
                        for i in 0..<3 {
                            sphere("\(side)-wheel\(i)", at: wheels[i], radius: 0.0762, color: .darkGray.withAlphaComponent(0.4))
                            line("\(side)-tread\(i)", wheels[i], wheels[(i + 1) % 3], radius: 0.022, color: .gray)
                        }
                    }
                }
            }
        }
        if let target = response.target {
            let point = position(target)
            let value = entity("target", mesh: ball, color: .orange.withAlphaComponent(0.65))
            value.position = point; value.scale = SIMD3(repeating: 0.013)
            // Target wrist axes expose orientation changes as well as XYZ.
            let q = target.quaternion
            let orientation = simd_quatf(ix: Float(q[0]), iy: Float(q[1]), iz: Float(q[2]), r: Float(q[3]))
            for (index, axis) in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)].enumerated() {
                let rob = orientation.act(axis) * 0.07
                line("target-axis\(index)", point, point + SIMD3(rob.y, rob.z, rob.x), radius: 0.003,
                     color: [UIColor.systemRed, .systemGreen, .systemBlue][index])
            }
        }
    }
}

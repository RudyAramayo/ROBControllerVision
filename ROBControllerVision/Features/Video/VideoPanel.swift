import CoreImage
import Foundation
import Metal
import Observation
import RealityKit
import ROBControlCore
import SwiftUI

struct VideoPanel: View {
    @Bindable var model: RobotViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    private var cameras: [CameraDescriptor] {
        model.snapshot.connection.handshake?.capabilities.cameras ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pilot Camera Matrix")
                        .font(.title2.bold())
                    Text("Each feed can be enabled independently for testing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if cameras.isEmpty {
                VideoUnavailableView(
                    isConnected: model.snapshot.connection.isReady,
                    cameraIsAvailable: false,
                    reason: model.snapshot.connection.handshake?.capabilities.videoUnavailableReason
                )
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                ForEach(cameras) { camera in
                    cameraCard(camera)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Material.thin)
        )
    }

    @ViewBuilder
    private func cameraCard(_ camera: CameraDescriptor) -> some View {
        let stream = model.activeVideoStream(for: camera.id)
        let pipeline = model.videoPipeline(for: camera.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: camera.id.rawValue == "insta360" ? "pano.fill" : "video.fill")
                    .foregroundStyle(stream == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(camera.name).font(.headline)
                    Text(stream == nil ? "Disabled" : pipeline.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if camera.id.rawValue == "insta360", stream != nil {
                    Button("360 Window", systemImage: "macwindow") {
                        openWindow(id: "insta360-window")
                    }
                    .buttonStyle(.bordered)
                    Button("Immersive", systemImage: "visionpro") {
                        Task { _ = await openImmersiveSpace(id: "insta360-immersive") }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(stream == nil ? "Enable" : "Disable") {
                    model.toggleVideoSubscription(cameraID: camera.id)
                }
                .buttonStyle(.bordered)
                .disabled(model.videoActionIsPending || !model.snapshot.connection.isReady)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.black)
                if let stream {
                    if camera.id.rawValue == "insta360" {
                        VStack(spacing: 10) {
                            Image(systemName: "pano.fill")
                                .font(.system(size: 42))
                            Text("Choose 360 Window or Immersive")
                                .font(.headline)
                            Text("The stream stays live while you switch presentation modes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.white)
                    } else {
                        ActiveVideoView(stream: stream, pipeline: pipeline)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.title)
                        Text("Enable this stream when it is needed")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(camera.id.rawValue == "insta360" ? 2 : 16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, minHeight: camera.id.rawValue == "front" ? 260 : 180)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.18))
        )
    }
}

struct ActiveVideoView: View {
    let stream: VideoStreamDescriptor
    let pipeline: VideoPipelineCoordinator
    var verticallyFlipped = false

    var body: some View {
        ZStack {
            SampleBufferVideoView(displayLayer: pipeline.displayLayer)
                .scaleEffect(x: 1, y: verticallyFlipped ? -1 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack {
                streamBadge
                Spacer()
                statisticsBadge
            }

            if case .starting = pipeline.state {
                ProgressView("Starting encoder and decoder…")
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Material.ultraThin)
                    )
            }
        }
    }

    private var streamBadge: some View {
        HStack {
            Label(pipeline.state.label, systemImage: "dot.radiowaves.left.and.right")
            Spacer()
            Text(streamDescription)
                .monospacedDigit()
        }
        .font(.caption.bold())
        .padding(10)
        .background(.black.opacity(0.62), in: Capsule())
        .padding(14)
    }

    private var statisticsBadge: some View {
        HStack {
            Text("Frames \(pipeline.statistics.renderedAccessUnits)")
            Spacer()
            Text("Received \(formattedReceivedBytes)")
            if pipeline.statistics.droppedAccessUnits > 0 {
                Spacer()
                Text("Dropped \(pipeline.statistics.droppedAccessUnits)")
                    .foregroundStyle(.yellow)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .background(.black.opacity(0.62), in: Capsule())
        .padding(14)
    }

    private var streamDescription: String {
        "\(stream.codec.rawValue.uppercased())  \(stream.width)×\(stream.height)  \(stream.framesPerSecond) fps"
    }

    private var formattedReceivedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: pipeline.statistics.receivedBytes),
            countStyle: .file
        )
    }
}

private struct VideoUnavailableView: View {
    let isConnected: Bool
    let cameraIsAvailable: Bool
    var reason: String? = nil

    private var title: String {
        if !isConnected { return "Connect to a robot" }
        return cameraIsAvailable ? "Camera ready" : "Cerebro video unavailable"
    }

    private var detail: String {
        if !isConnected {
            return "Connect first, then subscribe to start a negotiated H.264 stream."
        }
        if cameraIsAvailable {
            return "Select Subscribe to start the H.264 stream and Vision Pro decoder."
        }
        if let reason, !reason.isEmpty {
            return "\(reason) Cerebro video will retry automatically."
        }
        return
            "Robot control remains available. Waiting for Cerebro's camera service; video reconnects automatically when it is advertised."
    }

    var body: some View {
        VStack(spacing: 12) {
            if isConnected && !cameraIsAvailable {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 52))
            }
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}

struct Insta360WindowView: View {
    @Bindable var model: RobotViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    private var stream: VideoStreamDescriptor? {
        model.activeVideoStream(for: CameraID(rawValue: "insta360"))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Insta360 Pro • Equirectangular", systemImage: "pano.fill")
                    .font(.title2.bold())
                Spacer()
                Button("Enter Immersive", systemImage: "visionpro") {
                    Task {
                        if await openImmersiveSpace(id: "insta360-immersive") == .opened {
                            dismissWindow(id: "insta360-window")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(.black)
                if let stream {
                    ActiveVideoView(
                        stream: stream,
                        pipeline: model.insta360VideoPipeline,
                        verticallyFlipped: true
                    )
                } else {
                    ContentUnavailableView(
                        "Insta360 stream is disabled",
                        systemImage: "pano",
                        description: Text("Enable Insta360 in the Pilot Camera Matrix first.")
                    )
                }
            }
            .aspectRatio(2, contentMode: .fit)
        }
        .padding(24)
    }
}

struct Insta360ImmersiveView: View {
    @Bindable var model: RobotViewModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var renderer = Insta360SphereRenderer()

    var body: some View {
        RealityView { content in
            do {
                content.add(try renderer.makeSphere())
                renderer.start(pipeline: model.insta360VideoPipeline)
            } catch {
                renderer.errorMessage = error.localizedDescription
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // AVSampleBufferVideoRenderer needs a presentation target while
            // RealityKit copies its decoded pixel buffer into the sphere.
            SampleBufferVideoView(displayLayer: model.insta360VideoPipeline.displayLayer)
                .frame(width: 2, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            HStack(spacing: 12) {
                Label("LIVE 360°", systemImage: "pano.fill")
                if let errorMessage = renderer.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Button("Flat Window", systemImage: "macwindow") {
                    openWindow(id: "insta360-window")
                    Task { await dismissImmersiveSpace() }
                }
                Button("Exit", systemImage: "xmark") {
                    Task { await dismissImmersiveSpace() }
                }
            }
            .font(.headline)
            .padding(14)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 28)
        }
        .onDisappear { renderer.stop() }
    }
}

@MainActor
@Observable
private final class Insta360SphereRenderer {
    var errorMessage: String?

    @ObservationIgnored private var lowLevelTexture: LowLevelTexture?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private let device = MTLCreateSystemDefaultDevice()
    @ObservationIgnored private var commandQueue: MTLCommandQueue?
    @ObservationIgnored private var ciContext: CIContext?

    func makeSphere() throws -> Entity {
        guard let device else {
            throw Insta360SphereError.metalUnavailable
        }
        let descriptor = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .bgra8Unorm,
            width: 960,
            height: 480,
            depth: 1,
            mipmapLevelCount: 1,
            arrayLength: 1,
            // Core Image may use a compute kernel when rendering into this
            // texture, which requires shader-write access. Without it the
            // RealityKit material remains its initial black contents.
            textureUsage: [.shaderRead, .shaderWrite, .renderTarget]
        )
        let lowLevelTexture = try LowLevelTexture(descriptor: descriptor)
        let texture = try TextureResource(from: lowLevelTexture)
        var material = UnlitMaterial(texture: texture)
        material.faceCulling = .none
        material.readsDepth = false
        material.writesDepth = false

        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 10),
            materials: [material]
        )
        // Flip the generated sphere so its textured face and UVs are visible
        // from the pilot's position at the center.
        sphere.scale = SIMD3<Float>(-1, 1, 1)
        self.lowLevelTexture = lowLevelTexture
        guard let commandQueue = device.makeCommandQueue() else {
            throw Insta360SphereError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue
        ciContext = CIContext(mtlDevice: device)
        return sphere
    }

    func start(pipeline: VideoPipelineCoordinator) {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.drawLatestFrame(from: pipeline)
                try? await ContinuousClock().sleep(for: .milliseconds(33))
            }
        }
    }

    func stop() {
        renderTask?.cancel()
        renderTask = nil
    }

    private func drawLatestFrame(from pipeline: VideoPipelineCoordinator) {
        guard let pixelBuffer = pipeline.displayedPixelBuffer(),
              let lowLevelTexture,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext else { return }
        let destination = lowLevelTexture.replace(using: commandBuffer)
        let bounds = CGRect(x: 0, y: 0, width: destination.width, height: destination.height)
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let normalized = source.transformed(
            by: CGAffineTransform(
                translationX: -source.extent.minX,
                y: -source.extent.minY
            )
        )
        // The Insta360 preview arrives vertically inverted in its decoded
        // video surface. Correct it before RealityKit applies equirectangular
        // UVs to the inside of the sphere.
        let upright = normalized.transformed(
            by: CGAffineTransform(
                translationX: 0,
                y: normalized.extent.height
            ).scaledBy(x: 1, y: -1)
        )
        let fitted = upright.transformed(
            by: CGAffineTransform(
                scaleX: bounds.width / upright.extent.width,
                y: bounds.height / upright.extent.height
            )
        )
        ciContext.render(
            fitted,
            to: destination,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.commit()
    }
}

private enum Insta360SphereError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "The headset could not create the Metal renderer for the 360° sphere."
        case .commandQueueUnavailable:
            "The headset could not create the Metal command queue for the 360° sphere."
        }
    }
}

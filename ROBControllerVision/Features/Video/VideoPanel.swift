import CoreImage
import Foundation
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
        RealityView { content, attachments in
            do {
                content.add(try renderer.makeSphere())
                if let controls = attachments.entity(for: "insta360-controls") {
                    let controlsAnchor = AnchorEntity(.head, trackingMode: .once)
                    controls.position = SIMD3<Float>(0, 0.15, -1)
                    controlsAnchor.addChild(controls)
                    content.add(controlsAnchor)
                }
                renderer.start(pipeline: model.insta360VideoPipeline)
            } catch {
                renderer.errorMessage = error.localizedDescription
            }
        } attachments: {
            Attachment(id: "insta360-controls") {
                immersiveControls
            }
        }
        .onAppear {
            // An immersive transition may background the presenting window.
            // Keep the shared session and video subscriptions alive here.
            model.start()
            model.setSceneActive(true)
        }
        .onDisappear { renderer.stop() }
    }

    private var immersiveControls: some View {
        HStack(spacing: 12) {
            Label("LIVE 360°", systemImage: "pano.fill")
            Text(renderer.statusMessage)
                .foregroundStyle(.secondary)
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
        .glassBackgroundEffect(in: .capsule)
    }
}

@MainActor
@Observable
private final class Insta360SphereRenderer {
    var errorMessage: String?
    var statusMessage = "Preparing 360° texture…"

    @ObservationIgnored private static let textureWidth = 960
    @ObservationIgnored private static let textureHeight = 480
    @ObservationIgnored private var textureResource: TextureResource?
    @ObservationIgnored private var sphereEntity: ModelEntity?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private let ciContext = CIContext(
        options: [.cacheIntermediates: false]
    )
    @ObservationIgnored private var lastPresentedSequence: UInt64?
    @ObservationIgnored private var presentedFrameCount: UInt64 = 0

    func makeSphere() throws -> Entity {
        let texture = try makeDiagnosticTexture()
        let material = makeVideoMaterial(texture: texture)

        let sphere = ModelEntity(
            // Keep every ROBControllerVision window and normal room-scale
            // movement inside the panorama. A small sphere becomes a visible
            // circle and can depth-occlude the faster flat camera surfaces.
            mesh: .generateSphere(radius: 50),
            materials: [material]
        )
        sphere.name = "insta360-inward-sphere"

        // Capture the headset pose once when immersion begins. The panorama
        // starts around the viewer, then stays world-locked so head rotation
        // naturally looks around the equirectangular image.
        let root = AnchorEntity(.head, trackingMode: .once)
        root.addChild(sphere)
        textureResource = texture
        sphereEntity = sphere
        statusMessage = "Immersive renderer ready • waiting for video…"
        return root
    }

    func start(pipeline: VideoPipelineCoordinator) {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            let clock = ContinuousClock()
            let startedAt = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    switch try await drawLatestFrame(from: pipeline) {
                    case .noDecodedFrame:
                        if startedAt.duration(to: clock.now) > .seconds(2) {
                            statusMessage = "No decoded frame"
                            errorMessage = pipeline.decodedFrameError
                                ?? "Waiting for decoded Insta360 frames…"
                        }
                    case .unchanged:
                        break
                    case .presented:
                        errorMessage = nil
                        presentedFrameCount &+= 1
                        if presentedFrameCount == 1 || presentedFrameCount.isMultiple(of: 30) {
                            statusMessage = "Texture live • \(presentedFrameCount) frames"
                        }
                    }
                } catch {
                    statusMessage = "Texture upload failed"
                    errorMessage = error.localizedDescription
                }
                try? await clock.sleep(for: .milliseconds(33))
            }
        }
    }

    func stop() {
        renderTask?.cancel()
        renderTask = nil
        lastPresentedSequence = nil
        presentedFrameCount = 0
    }

    private func drawLatestFrame(
        from pipeline: VideoPipelineCoordinator
    ) async throws -> SphereFrameDrawResult {
        guard let frame = pipeline.decodedFrame() else { return .noDecodedFrame }
        guard frame.sequence != lastPresentedSequence else { return .unchanged }
        guard sphereEntity != nil else {
            throw Insta360SphereError.rendererNotReady
        }
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: Self.textureWidth,
            height: Self.textureHeight
        )
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
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
        guard let image = ciContext.createCGImage(fitted, from: bounds) else {
            throw Insta360SphereError.imageCreationFailed
        }
        // Create and bind a new GPU asset so the model's material observes
        // every decoded frame; in-place replacement remained black in the
        // immersive compositor even though the upload reported success.
        let nextTexture = try await TextureResource(
            image: image,
            withName: nil,
            options: .init(semantic: .color, mipmapsMode: .none)
        )
        sphereEntity?.model?.materials = [makeVideoMaterial(texture: nextTexture)]
        textureResource = nextTexture
        lastPresentedSequence = frame.sequence
        return .presented
    }

    private func makeVideoMaterial(texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial(texture: texture)
        // The equirectangular feed is viewed from the inside of the generated
        // sphere, so reverse U to preserve the camera's right-to-left view.
        material.textureCoordinateTransform = .init(
            offset: SIMD2<Float>(1, 0),
            scale: SIMD2<Float>(-1, 1)
        )
        // A generated sphere's front faces point outward. Cull those faces so
        // RealityKit draws only the back faces seen by the viewer inside it.
        material.faceCulling = .front
        material.readsDepth = true
        material.writesDepth = false
        return material
    }

    private func makeDiagnosticTexture() throws -> TextureResource {
        let width = Self.textureWidth
        let height = Self.textureHeight
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Insta360SphereError.imageCreationFailed
        }
        let tileWidth = width / 12
        let tileHeight = height / 6
        for row in 0..<6 {
            for column in 0..<12 {
                let alternate = (row + column).isMultiple(of: 2)
                context.setFillColor(
                    CGColor(
                        red: alternate ? 0.04 : 0.08,
                        green: alternate ? 0.14 : 0.38,
                        blue: alternate ? 0.55 : 0.82,
                        alpha: 1
                    )
                )
                context.fill(
                    CGRect(
                        x: column * tileWidth,
                        y: row * tileHeight,
                        width: tileWidth,
                        height: tileHeight
                    )
                )
            }
        }
        guard let image = context.makeImage() else {
            throw Insta360SphereError.imageCreationFailed
        }
        return try TextureResource(
            image: image,
            withName: "Insta360 immersive diagnostic",
            options: .init(semantic: .color, mipmapsMode: .none)
        )
    }

}

private enum SphereFrameDrawResult {
    case noDecodedFrame
    case unchanged
    case presented
}

private enum Insta360SphereError: LocalizedError {
    case rendererNotReady
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .rendererNotReady:
            "The 360° texture renderer is not ready."
        case .imageCreationFailed:
            "The decoded Insta360 frame could not be converted into a RealityKit image."
        }
    }
}

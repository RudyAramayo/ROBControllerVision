import SwiftUI
import Combine
#if os(visionOS)
import ROBControlCore
#endif

/// Shared operator surface. The server is authoritative; buttons never optimistically arm.
@MainActor final class ROBBubbleConsoleModel: ObservableObject {
    @Published var status: ROBBubbleStatus?
    @Published var imageData: Data?
    @Published var frameID: UUID?
    @Published var selectedPoint: CGPoint?
    @Published var pan = 4000.0
    @Published var tilt = 8000.0
    @Published var error = "Connect to Cerebro to use the bubble controls"
    @Published var simulationOnly = false
    @Published var useControllerButtons = false
    @Published var isVisible = false
    @Published var sceneActive = true
    var allowsAuthorization = true
    var send: ((ROBBubbleCommand) -> Void)?
    var visibilityChanged: ((Bool) -> Void)?
    private var lastReceived = 0.0
    private var lastFrameReceived = 0.0
    private var previousButtons = (false, false)
    private let uptime: () -> Double

    init(uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.uptime = uptime }
    var fresh: Bool { status != nil && uptime() - lastReceived < 1.5 }
    var armed: Bool { fresh && status?.armed == true }
    var canMove: Bool { fresh && (!allowsAuthorization || (status?.mountAuthorized ?? status?.armed) == true) }
    var canRunMotors: Bool { fresh && (!allowsAuthorization ? status?.cooldownSeconds == 0 : armed) }
    var canAuthorize: Bool { fresh && !armed && (status?.cooldownSeconds ?? 1) == 0 }
    var canEnableMount: Bool { fresh && !canMove }
    var outputMode: String {
        guard let status else { return "CONNECTING" }
        if status.motorsLive == true { return status.mountLive == true ? "LIVE MOUNT + MOTORS" : "LIVE MOTORS" }
        if status.mountLive == true { return "LIVE TILT / PAN" }
        return status.dryRun ? (simulationOnly ? "DRY RUN" : "READY TO ENABLE") : "LIVE OUTPUTS"
    }
    var cameraPlaceholder: String { fresh ? "Waiting for face-camera RGB" : "Waiting for Cerebro connection" }
    func authorize() {
        guard canAuthorize else { return }
        command(simulationOnly ? .authorize : .authorizeMotors)
    }
    func enableMount() {
        guard canEnableMount else { return }
        command(simulationOnly ? .authorize : .authorizeMount)
    }
    func consume(_ state: ROBBubbleStatus) {
        lastReceived = uptime(); status = state; error = ""
        if let jpeg = state.jpeg, let id = state.frameID {
            imageData = jpeg; frameID = id; lastFrameReceived = lastReceived
        }
    }
    func command(_ operation: ROBBubbleOperation) {
        guard let send else { error = "Waiting for the Cerebro control connection"; return }
        send(.init(operation))
    }
    func disconnected() {
        status = nil; imageData = nil; frameID = nil; selectedPoint = nil
        lastReceived = 0; lastFrameReceived = 0; simulationOnly = false
        useControllerButtons = false
        error = "Connect to an authenticated Cerebro session"
    }
    func poll() {
        guard isVisible, sceneActive else { return }
        if !fresh {
            status = nil; error = "Waiting for fresh bubble status from Cerebro"
        }
        if uptime() - lastFrameReceived > 2 {
            imageData = nil; frameID = nil
        }
        // Preserve a specific send failure (for example, not paired) instead
        // of immediately overwriting it with a generic camera/status message.
        command(.heartbeat); command(.preview)
    }
    func setVisible(_ visible: Bool) {
        isVisible = visible; visibilityChanged?(visible)
        if visible { poll() } else { command(.stop); useControllerButtons = false; simulationOnly = false }
    }
    func suspend() {
        command(.stop); sceneActive = false; status = nil; useControllerButtons = false
    }
    func select(u: Double, v: Double) {
        guard canMove, let frameID, uptime() - lastFrameReceived <= 2 else { return }
        selectedPoint = CGPoint(x: u, y: v)
        send?(.init(.aim, frameID: frameID, u: u, v: v))
    }
    func applyManual() {
        guard canMove else { return }
        send?(.init(.manual, pan: Int(pan.rounded()), tilt: Int(tilt.rounded())))
    }
    func controllerButtons(spin: Bool, blower: Bool) {
        defer { previousButtons = (spin, blower) }
        guard isVisible, sceneActive, useControllerButtons, armed else { return }
        if spin && !previousButtons.0 { command(status?.spin == true ? .spinOff : .spinOn) }
        if blower && !previousButtons.1 { command(status?.blower == true ? .blowerOff : .blowerOn) }
    }
}

struct ROBBubbleConsole: View {
    @ObservedObject var model: ROBBubbleConsoleModel
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Bubble targeting", systemImage: "bubbles.and.sparkles")
                        .font(.title2.bold())
                    Text(model.outputMode)
                        .font(.caption.bold()).foregroundStyle(model.status?.dryRun == false ? .orange : .cyan)
                }
                Text(model.error.isEmpty ? model.status?.detail ?? "" : model.error)
                    .font(.callout).foregroundStyle(.secondary)
                camera
                Text("Face-camera RGB • distance measured by aligned depth")
                    .font(.caption).foregroundStyle(.secondary)
                if model.fresh && model.status?.depthReady == false {
                    Text("Depth ranging is unavailable. Authorization and manual Tilt/Pan still work; camera targeting needs a distance measurement.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.status?.targetDescription ?? "Look and pinch, or tap a point in the camera to aim.")
                    .font(.callout.monospacedDigit())
                VStack(alignment: .leading, spacing: 4) {
                    Label(model.armed ? "Motors authorized" : "Motors disarmed", systemImage: model.armed ? "lock.open" : "lock")
                    Text(String(format: "Bubbles %.0f s • Cooldown %.0f s", model.status?.remainingSeconds ?? 0,
                                model.status?.cooldownSeconds ?? 0)).monospacedDigit()
                }.font(.callout)
                if model.allowsAuthorization && model.status?.mountLive == false && model.status?.motorsLive == false {
                    Toggle("Simulation only", isOn: $model.simulationOnly)
                        .disabled(model.armed || model.canMove)
                    Text("Enable Tilt/Pan to move the servos. Authorize bubbles separately to use the fan and blower. Neither needs a camera connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.simulationOnly {
                    Text("Dry run simulates movement and motors; it does not move the machine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.allowsAuthorization {
                    HStack {
                        Button(model.canMove ? "Tilt/Pan enabled" : "Enable Tilt/Pan") { model.enableMount() }
                            .disabled(!model.canEnableMount)
                        Button(model.simulationOnly ? "Authorize simulation" : "Authorize bubbles") { model.authorize() }
                            .disabled(!model.canAuthorize)
                    }.buttonStyle(.borderedProminent)
                } else {
                    Text("Cerebro · direct local control").font(.caption)
                }
                HStack {
                    Button("STOP", role: .destructive) { model.command(.stop) }
                    Button("Stow laser") { model.command(.stow) }.disabled(!model.canMove)
                }.buttonStyle(.borderedProminent)
                Button("Release Tilt/Pan · stop servo pulses") { model.command(.releaseMount) }
                    .font(.callout)
                HStack {
                    Button(model.status?.spin == true ? "Stop fan" : "Start fan") {
                        model.command(model.status?.spin == true ? .spinOff : .spinOn)
                    }
                    Button(model.status?.blower == true ? "Stop bubbles" : "Start bubbles") {
                        model.command(model.status?.blower == true ? .blowerOff : .blowerOn)
                    }.disabled(model.status?.spinReady != true && model.status?.blower != true)
                }.buttonStyle(.bordered).disabled(!model.canRunMotors)
                HStack {
                    Button("Pulse · 3 s / 5 s") { model.command(.pulse) }
                    Button("Continuous · timed") { model.command(.continuous) }
                }.buttonStyle(.bordered).disabled(!model.canRunMotors)
                Text("Fan-only operation does not use bubble time. Bubbles have a 2 min working limit, then 1 min off to cool. Relay settling takes 0.5 s. Continuous mode stops at the limit and requires fresh authorization.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Manual Tilt / Pan") {
                    VStack {
                        HStack { Text("Tilt \(Int(model.tilt))"); Slider(value: $model.tilt, in: 4000...8000, step: 1) }
                        HStack { Text("Pan \(Int(model.pan))"); Slider(value: $model.pan, in: 4000...8000, step: 1) }
                        Button("Apply mount position") { model.applyManual() }.disabled(!model.canMove)
                        Text("Startup rest: Tilt 8000 · Pan 4000 · Fan 4000 · Bubbles 4000")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                #if os(visionOS)
                Toggle("Use controller X / Y for fan / bubbles", isOn: $model.useControllerButtons)
                    .disabled(!model.armed)
                Text("Look at the camera grid and pinch to select a target. X toggles the fan; Y toggles bubbles after the fan settles. Closing this panel stops both.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }.padding(20)
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
        .onReceive(ticker) { _ in model.poll() }
    }

    private var camera: some View {
        Group {
            if let data = model.imageData, let picture = platformImage(data) {
                picture.image.resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            #if os(visionOS)
                            // Native buttons receive gaze focus without collecting raw gaze.
                            VStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { row in
                                    HStack(spacing: 0) {
                                        ForEach(0..<11, id: \.self) { column in
                                            Button {
                                                model.select(u: (Double(column) + 0.5) / 11, v: (Double(row) + 0.5) / 7)
                                            } label: {
                                                Rectangle().fill(.white.opacity(0.001))
                                                    .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                                            }
                                            .buttonStyle(.plain).hoverEffect(.highlight)
                                            .accessibilityLabel("Aim row \(row + 1), column \(column + 1)")
                                        }
                                    }
                                }
                            }.disabled(!model.canMove)
                            #else
                            Color.clear.contentShape(Rectangle()).gesture(
                                DragGesture(minimumDistance: 0).onEnded { event in
                                    guard abs(event.translation.width) < 10, abs(event.translation.height) < 10 else { return }
                                    model.select(u: event.location.x / geometry.size.width,
                                                 v: event.location.y / geometry.size.height)
                                }
                            )
                            #endif
                            if let point = model.selectedPoint {
                                Image(systemName: "scope").font(.system(size: 30)).foregroundStyle(.cyan)
                                    .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.5))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { Label(model.cameraPlaceholder, systemImage: "camera.viewfinder") }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func platformImage(_ data: Data) -> (image: Image, size: CGSize)? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return (Image(nsImage: image), image.size)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return (Image(uiImage: image), image.size)
        #endif
    }
}

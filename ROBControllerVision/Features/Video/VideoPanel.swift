import Foundation
import ROBControlCore
import SwiftUI

struct VideoPanel: View {
    @Bindable var model: RobotViewModel

    private var stream: VideoStreamDescriptor? {
        model.snapshot.videoStreams.first
    }

    private var actionTitle: String {
        if model.videoActionIsPending { return "Working…" }
        return stream == nil ? "Subscribe" : "Unsubscribe"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black)

                if let stream {
                    ActiveVideoView(stream: stream, pipeline: model.videoPipeline)
                } else {
                    VideoUnavailableView(
                        isConnected: model.snapshot.connection.isReady,
                        cameraIsAvailable:
                            model.snapshot.connection.handshake?.capabilities.cameras.isEmpty
                            == false
                    )
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, minHeight: 560)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ROB Wide Camera")
                    .font(.title2.bold())
                Text(stream == nil ? "No active subscription" : model.videoPipeline.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle) {
                model.toggleVideoSubscription()
            }
            .buttonStyle(.bordered)
            .disabled(
                model.videoActionIsPending
                    || !model.snapshot.connection.isReady
                    || model.snapshot.connection.handshake?.capabilities.cameras.isEmpty != false
            )
        }
    }
}

private struct ActiveVideoView: View {
    let stream: VideoStreamDescriptor
    let pipeline: VideoPipelineCoordinator

    var body: some View {
        ZStack {
            SampleBufferVideoView(displayLayer: pipeline.displayLayer)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack {
                streamBadge
                Spacer()
                statisticsBadge
            }

            if case .starting = pipeline.state {
                ProgressView("Starting encoder and decoder…")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
        return
            "Robot control remains available. Check Cerebro's camera service, then reconnect to advertise its camera."
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 52))
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

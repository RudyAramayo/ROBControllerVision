import AVFoundation
import CoreVideo
import Foundation
import Observation
import ROBControlCore
import ROBVideoPipeline

enum VideoPipelineState: Equatable {
    case idle
    case starting
    case streaming
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting H.264 pipeline…"
        case .streaming: "Live H.264"
        case .failed(let message): "Video failed: \(message)"
        }
    }
}

@MainActor
@Observable
final class VideoPipelineCoordinator {
    private(set) var state: VideoPipelineState = .idle
    private(set) var statistics = VideoReceiverStatistics()
    private(set) var decodedFrameError: String?
    let displayLayer: AVSampleBufferDisplayLayer

    @ObservationIgnored private var receiver: H264VideoReceiver?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var pipelineID: UUID?
    @ObservationIgnored private var closeDataStream: (@Sendable () async -> Void)?
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private let capturesDecodedFrames: Bool
    @ObservationIgnored private let decodedFrameStore = LatestVideoPixelBufferStore()

    init(capturesDecodedFrames: Bool = false) {
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        self.displayLayer = displayLayer
        self.capturesDecodedFrames = capturesDecodedFrames
    }

    /// Supplies the newest decoded frame to RealityKit independently of display-layer visibility.
    func decodedFrame() -> (pixelBuffer: CVPixelBuffer, sequence: UInt64)? {
        decodedFrameStore.current()
    }

    deinit {
        receiveTask?.cancel()
        let receiver = receiver
        let closeDataStream = closeDataStream
        Task {
            await receiver?.stop()
            await closeDataStream?()
        }
    }

    func start(
        stream: VideoStreamDescriptor,
        sessionID: UUID,
        session: RobotSession
    ) async {
        guard !Task.isCancelled else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        await tearDownCurrentPipeline()
        guard lifecycleGeneration == generation, !Task.isCancelled else { return }

        let newPipelineID = UUID()
        pipelineID = newPipelineID
        state = .starting
        statistics = VideoReceiverStatistics()
        decodedFrameError = nil
        decodedFrameStore.clear()
        var unownedOpenedChannelID: UUID?

        do {
            let dataChannel = try await session.openVideoDataStream(for: stream.id)
            unownedOpenedChannelID = dataChannel.id
            let closeOpenedChannel: @Sendable () async -> Void = {
                await session.closeVideoDataChannel(dataChannel.id)
            }
            guard lifecycleGeneration == generation,
                pipelineID == newPipelineID,
                !Task.isCancelled
            else {
                await closeOpenedChannel()
                unownedOpenedChannelID = nil
                return
            }
            let rendererHandle = SampleBufferVideoRendererHandle(
                displayLayer.sampleBufferRenderer
            )
            let decodedFrameStore = decodedFrameStore
            let decodedPixelBufferHandler: H264VideoReceiver.DecodedPixelBufferHandler?
            if capturesDecodedFrames {
                decodedPixelBufferHandler = { @Sendable pixelBuffer in
                    decodedFrameStore.replace(with: pixelBuffer)
                }
            } else {
                decodedPixelBufferHandler = nil
            }
            let receiver = try H264VideoReceiver(
                sessionID: sessionID,
                stream: stream,
                rendererHandle: rendererHandle,
                statisticsHandler: { [weak self] statistics in
                    Task { @MainActor in
                        guard let self, self.pipelineID == newPipelineID else { return }
                        self.statistics = statistics
                        if statistics.renderedAccessUnits > 0 {
                            self.state = .streaming
                        }
                    }
                },
                keyFrameRequestHandler: {
                    Task {
                        try? await session.sendVideoFeedback(
                            VideoReceiverFeedback(
                                id: stream.id,
                                estimatedPacketLoss: 0,
                                estimatedJitterMilliseconds: 0,
                                decodedFramesPerSecond: 0,
                                requestsKeyFrame: true
                            )
                        )
                    }
                },
                decodedPixelBufferHandler: decodedPixelBufferHandler,
                decodedPixelBufferErrorHandler: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.pipelineID == newPipelineID else { return }
                        self.decodedFrameError = error.localizedDescription
                    }
                }
            )
            guard lifecycleGeneration == generation,
                pipelineID == newPipelineID,
                !Task.isCancelled
            else {
                await receiver.stop()
                await closeOpenedChannel()
                unownedOpenedChannelID = nil
                return
            }

            self.receiver = receiver
            closeDataStream = closeOpenedChannel
            unownedOpenedChannelID = nil
            receiveTask = Task { [weak self] in
                do {
                    try await receiver.consume(dataChannel.messages)
                    guard !Task.isCancelled else { return }
                    await self?.finishPipeline(
                        id: newPipelineID,
                        errorMessage: "The video data channel ended."
                    )
                } catch is CancellationError {
                    return
                } catch {
                    await self?.finishPipeline(
                        id: newPipelineID,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        } catch is CancellationError {
            if let unownedOpenedChannelID {
                await session.closeVideoDataChannel(unownedOpenedChannelID)
            }
            guard lifecycleGeneration == generation, pipelineID == newPipelineID else { return }
            pipelineID = nil
            state = .idle
        } catch {
            if let unownedOpenedChannelID {
                await session.closeVideoDataChannel(unownedOpenedChannelID)
            }
            guard lifecycleGeneration == generation, pipelineID == newPipelineID else { return }
            pipelineID = nil
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard !Task.isCancelled else { return }
        lifecycleGeneration &+= 1
        await tearDownCurrentPipeline()
    }

    private func tearDownCurrentPipeline() async {
        let activeTask = receiveTask
        let activeReceiver = receiver
        let closeDataStream = closeDataStream
        receiveTask = nil
        pipelineID = nil
        receiver = nil
        self.closeDataStream = nil
        state = .idle
        statistics = VideoReceiverStatistics()
        decodedFrameError = nil
        decodedFrameStore.clear()

        activeTask?.cancel()
        if let activeReceiver {
            await activeReceiver.stop()
        }
        // `stop()` waits for outstanding VideoToolbox callbacks. Clear again
        // afterward so a late frame from the retired decoder cannot seed the
        // next immersive session with stale video.
        decodedFrameStore.clear()
        await closeDataStream?()
    }

    private func finishPipeline(id: UUID, errorMessage: String) async {
        guard pipelineID == id else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        await tearDownCurrentPipeline()
        guard lifecycleGeneration == generation else { return }
        state = .failed(errorMessage)
    }
}

private nonisolated final class LatestVideoPixelBufferStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?
    private var sequence: UInt64 = 0

    func replace(with pixelBuffer: CVPixelBuffer) {
        lock.lock()
        self.pixelBuffer = pixelBuffer
        sequence &+= 1
        lock.unlock()
    }

    func current() -> (pixelBuffer: CVPixelBuffer, sequence: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let pixelBuffer else { return nil }
        return (pixelBuffer, sequence)
    }

    func clear() {
        lock.lock()
        pixelBuffer = nil
        sequence = 0
        lock.unlock()
    }
}

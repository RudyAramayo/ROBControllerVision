import AVFoundation
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
        case .streaming: "Live synthetic H.264"
        case .failed(let message): "Video failed: \(message)"
        }
    }
}

@MainActor
@Observable
final class VideoPipelineCoordinator {
    private(set) var state: VideoPipelineState = .idle
    private(set) var statistics = VideoReceiverStatistics()
    let displayLayer: AVSampleBufferDisplayLayer

    @ObservationIgnored private var receiver: H264VideoReceiver?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var pipelineID: UUID?
    @ObservationIgnored private var closeDataStream: (@Sendable () async -> Void)?
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0

    init() {
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        self.displayLayer = displayLayer
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

        activeTask?.cancel()
        if let activeReceiver {
            await activeReceiver.stop()
        }
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

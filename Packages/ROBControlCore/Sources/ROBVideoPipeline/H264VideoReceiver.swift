import AVFoundation
import CoreMedia
import Foundation
import ROBControlCore

/// Apple documents `AVSampleBufferVideoRenderer` as safe for background enqueueing. Its SDK
/// annotation does not currently satisfy Swift 6 region isolation when the renderer originates
/// from a main-actor display layer, so this narrow handle records that framework guarantee.
public final class SampleBufferVideoRendererHandle: @unchecked Sendable {
    fileprivate let renderer: AVSampleBufferVideoRenderer

    public init(_ renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }
}

public struct VideoReceiverStatistics: Equatable, Sendable {
    public var receivedAccessUnits: UInt64
    public var renderedAccessUnits: UInt64
    public var droppedAccessUnits: UInt64
    public var keyFrameRequests: UInt64
    public var receivedBytes: UInt64
    public var lastSequence: UInt64?

    public init(
        receivedAccessUnits: UInt64 = 0,
        renderedAccessUnits: UInt64 = 0,
        droppedAccessUnits: UInt64 = 0,
        keyFrameRequests: UInt64 = 0,
        receivedBytes: UInt64 = 0,
        lastSequence: UInt64? = nil
    ) {
        self.receivedAccessUnits = receivedAccessUnits
        self.renderedAccessUnits = renderedAccessUnits
        self.droppedAccessUnits = droppedAccessUnits
        self.keyFrameRequests = keyFrameRequests
        self.receivedBytes = receivedBytes
        self.lastSequence = lastSequence
    }
}

public actor H264VideoReceiver {
    public typealias StatisticsHandler = @Sendable (VideoReceiverStatistics) -> Void
    public typealias KeyFrameRequestHandler = @Sendable () -> Void

    private let renderer: AVSampleBufferVideoRenderer
    private let statisticsHandler: StatisticsHandler
    private let keyFrameRequestHandler: KeyFrameRequestHandler
    private let expectedWidth: Int
    private let expectedHeight: Int
    private var validator: VideoStreamValidator
    private let sampleBufferFactory = H264SampleBufferFactory()
    private let clock = ContinuousClock()

    private var statistics = VideoReceiverStatistics()
    private var lastStatisticsUpdate: ContinuousClock.Instant?
    private var isRecovering = false
    private var recoveryHasFlushedDecoder = false
    private var lastKeyFrameRequest: ContinuousClock.Instant?
    private var flushGeneration: UInt64 = 0
    private var codecConfigurationGeneration: UInt32?

    public init(
        sessionID: UUID,
        stream: VideoStreamDescriptor,
        rendererHandle: SampleBufferVideoRendererHandle,
        statisticsHandler: @escaping StatisticsHandler = { _ in },
        keyFrameRequestHandler: @escaping KeyFrameRequestHandler = {}
    ) throws {
        guard stream.codec == .h264 else {
            throw VideoPipelineError.unsupportedCodec(stream.codec.rawValue)
        }
        self.renderer = rendererHandle.renderer
        self.statisticsHandler = statisticsHandler
        self.keyFrameRequestHandler = keyFrameRequestHandler
        self.expectedWidth = Int(stream.width)
        self.expectedHeight = Int(stream.height)
        self.validator = VideoStreamValidator(sessionID: sessionID, stream: stream)
    }

    public func consume(_ stream: RobotVideoDataStream) async throws {
        defer { publishStatistics(force: true) }

        for try await message in stream {
            try Task.checkCancellation()
            do {
                switch message {
                case .codecConfiguration(let configuration):
                    _ = try validator.accept(message)
                    try await configureDecoder(with: configuration)

                case .accessUnit(let accessUnit):
                    statistics.receivedAccessUnits &+= 1
                    statistics.receivedBytes &+= UInt64(accessUnit.payload.count)
                    statistics.lastSequence = accessUnit.sequence

                    guard let accepted = try validator.accept(message) else { continue }
                    try await enqueue(accepted)
                }
            } catch let validationError as VideoDataValidationError
                where validationError.shouldRequestKeyFrame
            {
                statistics.droppedAccessUnits &+= 1
                await recoverDecoder()
            } catch let validationError as VideoDataValidationError
                where validationError.isDiscardableByReceiver
            {
                statistics.droppedAccessUnits &+= 1
            }
            publishStatistics()
        }
    }

    public func stop() async {
        flushGeneration &+= 1
        await flushRenderer(removingDisplayedImage: true)
        sampleBufferFactory.reset()
        validator.requireKeyFrame()
        isRecovering = true
        recoveryHasFlushedDecoder = true
        lastKeyFrameRequest = nil
        codecConfigurationGeneration = nil
        publishStatistics(force: true)
    }

    private func configureDecoder(with configuration: VideoCodecConfiguration) async throws {
        let parameterSets = configuration.parameterSets
            .filter { $0.kind == .sps || $0.kind == .pps }
            .sorted { lhs, rhs in
                if lhs.kind == rhs.kind { return lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
                return lhs.kind == .sps
            }
            .map(\.bytes)
        try sampleBufferFactory.configure(
            parameterSets: parameterSets,
            nalUnitHeaderLength: Int(configuration.nalLengthFieldBytes),
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight
        )
        if let codecConfigurationGeneration,
            codecConfigurationGeneration != configuration.generation
        {
            flushGeneration &+= 1
            let generation = flushGeneration
            await flushRenderer(removingDisplayedImage: false)
            guard flushGeneration == generation else { throw CancellationError() }
            isRecovering = true
            recoveryHasFlushedDecoder = true
            lastKeyFrameRequest = nil
        }
        codecConfigurationGeneration = configuration.generation
    }

    private func enqueue(_ accessUnit: EncodedVideoAccessUnit) async throws {
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            statistics.droppedAccessUnits &+= 1
            await recoverDecoder(forceFlush: true)
            return
        }
        if !renderer.isReadyForMoreMediaData {
            let becameReady = try await waitForRendererReadiness()
            if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
                statistics.droppedAccessUnits &+= 1
                await recoverDecoder(forceFlush: true)
                return
            }
            guard becameReady else {
                statistics.droppedAccessUnits &+= 1
                await recoverDecoder()
                return
            }
        }
        guard renderer.isReadyForMoreMediaData else {
            statistics.droppedAccessUnits &+= 1
            await recoverDecoder()
            return
        }

        let sampleBuffer = try sampleBufferFactory.makeSampleBuffer(
            payload: accessUnit.payload,
            presentationTime: CMTime(
                value: accessUnit.presentationTimestamp,
                timescale: accessUnit.timescale
            ),
            duration: CMTime(value: accessUnit.duration, timescale: accessUnit.timescale),
            isKeyFrame: accessUnit.isKeyFrame
        )
        renderer.enqueue(sampleBuffer)
        statistics.renderedAccessUnits &+= 1
        if accessUnit.isKeyFrame {
            isRecovering = false
            recoveryHasFlushedDecoder = false
            lastKeyFrameRequest = nil
        }
    }

    private func recoverDecoder(forceFlush: Bool = false) async {
        validator.requireKeyFrame()
        let wasRecovering = isRecovering
        isRecovering = true
        if forceFlush || !recoveryHasFlushedDecoder {
            flushGeneration &+= 1
            let generation = flushGeneration
            await flushRenderer(removingDisplayedImage: false)
            guard flushGeneration == generation else { return }
            recoveryHasFlushedDecoder = true
        }

        let now = clock.now
        if wasRecovering,
            let lastKeyFrameRequest,
            lastKeyFrameRequest.duration(to: now) < .milliseconds(500)
        {
            return
        }
        lastKeyFrameRequest = now
        statistics.keyFrameRequests &+= 1
        keyFrameRequestHandler()
    }

    private func flushRenderer(removingDisplayedImage: Bool) async {
        await withCheckedContinuation { continuation in
            renderer.flush(removingDisplayedImage: removingDisplayedImage) {
                continuation.resume()
            }
        }
    }

    private func waitForRendererReadiness() async throws -> Bool {
        let deadline = clock.now.advanced(by: .milliseconds(50))
        while !renderer.isReadyForMoreMediaData,
            !renderer.requiresFlushToResumeDecoding,
            renderer.status != .failed,
            clock.now < deadline
        {
            try Task.checkCancellation()
            try await clock.sleep(for: .milliseconds(2))
        }
        return renderer.isReadyForMoreMediaData
    }

    private func publishStatistics(force: Bool = false) {
        let now = clock.now
        if !force,
            let lastStatisticsUpdate,
            lastStatisticsUpdate.duration(to: now) < .milliseconds(500)
        {
            return
        }
        lastStatisticsUpdate = now
        statisticsHandler(statistics)
    }
}

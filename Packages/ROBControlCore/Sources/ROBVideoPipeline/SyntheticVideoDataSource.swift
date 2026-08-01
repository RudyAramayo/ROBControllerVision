import Foundation
import ROBControlCore

public actor SyntheticVideoDataSource: RobotVideoDataSource {
    public nonisolated let supportedCodecs: Set<VideoCodec> = [.h264]
    public nonisolated let supportedDeliveryModes: Set<VideoDeliveryMode> = [.quicDatagrams]
    public nonisolated let maximumBitrate: UInt32 = 8_000_000

    private struct SubscriptionKey: Hashable, Sendable {
        let sessionID: UUID
        let subscriptionID: VideoSubscriptionID
    }

    private struct ProducerRecord {
        let key: SubscriptionKey
        let producer: SyntheticVideoProducer
    }

    private var producers: [UUID: ProducerRecord] = [:]
    private var activeChannels: [SubscriptionKey: UUID] = [:]

    public init() {}

    public func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) async throws -> RobotVideoDataChannel {
        try stream.validateForVideoDataChannel()
        guard stream.codec == .h264 else {
            throw VideoPipelineError.unsupportedCodec(stream.codec.rawValue)
        }
        guard supportedDeliveryModes.contains(stream.delivery) else {
            throw VideoPipelineError.unsupportedDeliveryMode(stream.delivery.rawValue)
        }
        guard stream.bitrate <= maximumBitrate else {
            throw VideoPipelineError.bitrateExceedsSourceLimit(
                actual: stream.bitrate,
                maximum: maximumBitrate
            )
        }

        let key = SubscriptionKey(sessionID: sessionID, subscriptionID: stream.id)
        let channelID = UUID()
        let terminationGate = VideoProducerTerminationGate()
        let channel = try BoundedInMemoryVideoChannel(
            capacity: 4,
            terminationHandler: { [weak self] in
                terminationGate.requestTermination()
                Task {
                    await self?.consumerTerminatedChannel(channelID)
                }
            }
        )
        let producer = SyntheticVideoProducer(
            sessionID: sessionID,
            stream: stream,
            channel: channel,
            terminationGate: terminationGate
        )
        let previousChannelID = activeChannels.updateValue(channelID, forKey: key)
        producers[channelID] = ProducerRecord(key: key, producer: producer)

        if let previousChannelID,
            let previous = producers.removeValue(forKey: previousChannelID)
        {
            await previous.producer.stop()
        }

        do {
            try await producer.start()
            guard activeChannels[key] == channelID else {
                producers.removeValue(forKey: channelID)
                await producer.stop()
                throw VideoDataTransportError.channelSuperseded
            }
            return RobotVideoDataChannel(
                id: channelID,
                sessionID: sessionID,
                descriptor: stream,
                messages: channel.stream
            )
        } catch {
            producers.removeValue(forKey: channelID)
            if activeChannels[key] == channelID {
                activeChannels.removeValue(forKey: key)
            }
            await producer.stop()
            throw error
        }
    }

    public func closeVideoDataChannel(_ id: UUID) async {
        guard let record = producers.removeValue(forKey: id) else { return }
        if activeChannels[record.key] == id {
            activeChannels.removeValue(forKey: record.key)
        }
        await record.producer.stop()
    }

    public func closeVideoDataStreams(
        sessionID: UUID,
        subscriptionID: VideoSubscriptionID
    ) async {
        let key = SubscriptionKey(sessionID: sessionID, subscriptionID: subscriptionID)
        guard let channelID = activeChannels.removeValue(forKey: key),
            let record = producers.removeValue(forKey: channelID)
        else { return }
        await record.producer.stop()
    }

    public func closeAllVideoDataStreams(sessionID: UUID) async {
        let channelIDs = producers.compactMap { channelID, record in
            record.key.sessionID == sessionID ? channelID : nil
        }
        let records = channelIDs.compactMap { producers.removeValue(forKey: $0) }
        activeChannels = activeChannels.filter { $0.key.sessionID != sessionID }
        for record in records {
            await record.producer.stop()
        }
    }

    public func handleVideoFeedback(
        _ feedback: VideoReceiverFeedback,
        sessionID: UUID
    ) async {
        let key = SubscriptionKey(sessionID: sessionID, subscriptionID: feedback.id)
        guard feedback.requestsKeyFrame,
            let channelID = activeChannels[key],
            let record = producers[channelID]
        else { return }
        await record.producer.requestKeyFrame()
    }

    private func consumerTerminatedChannel(_ id: UUID) async {
        guard let record = producers.removeValue(forKey: id) else { return }
        if activeChannels[record.key] == id {
            activeChannels.removeValue(forKey: record.key)
        }
        await record.producer.stop()
    }
}

private actor SyntheticVideoProducer {
    private let sessionID: UUID
    private let stream: VideoStreamDescriptor
    private let channel: BoundedInMemoryVideoChannel
    private let keyFrameRequests = KeyFrameRequestGate()
    private let terminationGate: VideoProducerTerminationGate

    private var generationTask: Task<Void, Never>?
    private var encoder: H264VideoEncoder?
    private var source: SyntheticPixelBufferSource?

    init(
        sessionID: UUID,
        stream: VideoStreamDescriptor,
        channel: BoundedInMemoryVideoChannel,
        terminationGate: VideoProducerTerminationGate
    ) {
        self.sessionID = sessionID
        self.stream = stream
        self.channel = channel
        self.terminationGate = terminationGate
    }

    func start() throws {
        guard generationTask == nil else { return }

        let sessionID = sessionID
        let stream = stream
        let channel = channel
        let keyFrameRequests = keyFrameRequests
        let terminationGate = terminationGate
        let configurationTracker = CodecConfigurationTracker()
        source = try SyntheticPixelBufferSource(
            width: Int(stream.width),
            height: Int(stream.height)
        )
        encoder = try H264VideoEncoder(
            width: Int(stream.width),
            height: Int(stream.height),
            framesPerSecond: Int(stream.framesPerSecond),
            averageBitrate: Int(stream.bitrate)
        ) { result in
            switch result {
            case .success(let frame):
                do {
                    let messages = try Self.messages(
                        for: frame,
                        sessionID: sessionID,
                        stream: stream,
                        configurationTracker: configurationTracker
                    )
                    for message in messages {
                        let offerResult = channel.offer(message)
                        if offerResult == .droppedOldest {
                            keyFrameRequests.request()
                        } else if offerResult == .terminated {
                            terminationGate.requestTermination()
                        } else if case .rejected = offerResult {
                            terminationGate.requestTermination()
                            channel.finish(throwing: VideoPipelineError.channelClosed)
                        }
                    }
                } catch {
                    terminationGate.requestTermination()
                    channel.finish(throwing: error)
                }
            case .failure(.encodedFrameDropped):
                keyFrameRequests.request()
            case .failure(let error):
                terminationGate.requestTermination()
                channel.finish(throwing: error)
            }
        }

        generationTask = Task { [weak self] in
            await self?.generateFrames()
        }
    }

    func stop() async {
        let task = generationTask
        generationTask = nil
        task?.cancel()
        terminationGate.requestTermination()
        if let task {
            await task.value
        }
        finishResources()
    }

    func requestKeyFrame() {
        keyFrameRequests.request()
    }

    private func generateFrames() async {
        guard let source, let encoder else { return }
        defer {
            generationTask = nil
            finishResources()
        }

        let framesPerSecond = max(1, Int(stream.framesPerSecond))
        let durationMicroseconds = UInt32(max(1, 1_000_000 / framesPerSecond))
        let interval = Duration.microseconds(Int64(durationMicroseconds))
        let timer = ContinuousClock()
        var sequence: UInt64 = 1

        while !Task.isCancelled && !terminationGate.terminationWasRequested() {
            var didEncodeFrame = false
            do {
                let pixelBuffer = try source.makeFrame(sequence: sequence)
                let presentationTime = Int64(sequence - 1) * Int64(durationMicroseconds)
                try encoder.encode(
                    pixelBuffer,
                    sequence: sequence,
                    presentationTimeMicroseconds: presentationTime,
                    durationMicroseconds: durationMicroseconds,
                    forceKeyFrame: keyFrameRequests.consume()
                )
                didEncodeFrame = true
            } catch VideoPipelineError.pixelBufferPoolExhausted {
                // VideoToolbox still owns all pooled buffers. Drop this capture attempt instead of
                // allocating without bound or delaying the independent control channel.
            } catch {
                terminationGate.requestTermination()
                channel.finish(throwing: error)
                return
            }

            guard !terminationGate.terminationWasRequested() else { return }

            if didEncodeFrame {
                sequence &+= 1
            }
            do {
                try await timer.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    private func finishResources() {
        encoder?.finish()
        encoder = nil
        source = nil
        channel.finish()
    }

    nonisolated private static func messages(
        for frame: H264EncodedFrame,
        sessionID: UUID,
        stream: VideoStreamDescriptor,
        configurationTracker: CodecConfigurationTracker
    ) throws -> [VideoDataMessage] {
        var messages: [VideoDataMessage] = []
        let configurationGeneration: UInt32

        if frame.isKeyFrame {
            guard let rawParameterSets = frame.parameterSets else {
                throw VideoPipelineError.invalidCodecConfiguration
            }
            configurationGeneration = try configurationTracker.generation(
                for: rawParameterSets,
                nalUnitHeaderLength: frame.nalUnitHeaderLength
            )
            let parameterSets = try rawParameterSets.map { bytes -> VideoCodecParameterSet in
                guard let firstByte = bytes.first else {
                    throw VideoPipelineError.invalidCodecConfiguration
                }
                switch firstByte & 0x1F {
                case 7:
                    return try VideoCodecParameterSet(kind: .sps, bytes: bytes)
                case 8:
                    return try VideoCodecParameterSet(kind: .pps, bytes: bytes)
                default:
                    throw VideoPipelineError.invalidCodecConfiguration
                }
            }
            let configuration = try VideoCodecConfiguration(
                sessionID: sessionID,
                streamID: stream.id,
                codec: .h264,
                generation: configurationGeneration,
                parameterSets: parameterSets,
                nalLengthFieldBytes: frame.nalUnitHeaderLength
            )
            messages.append(.codecConfiguration(configuration))
        } else {
            guard let currentGeneration = configurationTracker.currentGeneration() else {
                throw VideoPipelineError.invalidCodecConfiguration
            }
            configurationGeneration = currentGeneration
        }

        let accessUnit = try EncodedVideoAccessUnit(
            sessionID: sessionID,
            streamID: stream.id,
            codec: .h264,
            sequence: frame.sequence,
            captureTimestampUnixMilliseconds: Int64(
                (Date().timeIntervalSince1970 * 1_000).rounded()
            ),
            presentationTimestamp: frame.presentationTimeMicroseconds,
            duration: Int64(frame.durationMicroseconds),
            timescale: 1_000_000,
            isKeyFrame: frame.isKeyFrame,
            codecConfigurationGeneration: configurationGeneration,
            payload: frame.payload
        )
        messages.append(.accessUnit(accessUnit))
        return messages
    }
}

private final class CodecConfigurationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var parameterSets: [Data]?
    private var nalUnitHeaderLength: UInt8?
    private var generation: UInt32 = 0

    func generation(
        for parameterSets: [Data],
        nalUnitHeaderLength: UInt8
    ) throws -> UInt32 {
        lock.lock()
        defer { lock.unlock() }

        if self.parameterSets == parameterSets,
            self.nalUnitHeaderLength == nalUnitHeaderLength
        {
            return generation
        }
        guard generation < UInt32.max else {
            throw VideoPipelineError.codecConfigurationGenerationExhausted
        }
        generation += 1
        self.parameterSets = parameterSets
        self.nalUnitHeaderLength = nalUnitHeaderLength
        return generation
    }

    func currentGeneration() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return generation > 0 ? generation : nil
    }
}

import Foundation
import ROBControlCore
import Testing

@testable import ROBVideoPipeline

@Suite("Encoded video pipeline integration")
struct VideoPipelineIntegrationTests {
    @Test("Invalid bounded-channel capacities are rejected")
    func invalidChannelCapacity() {
        #expect(throws: VideoPipelineError.self) {
            _ = try BoundedInMemoryVideoChannel(capacity: 0)
        }
    }

    @Test("The bounded data channel drops stale media without blocking")
    func boundedChannelDropsOldestMessage() async throws {
        let channel = try BoundedInMemoryVideoChannel(capacity: 1)
        let first = try jpegMessage(sequence: 1)
        let second = try jpegMessage(sequence: 2)

        #expect(channel.offer(first) == .enqueued)
        #expect(channel.offer(second) == .droppedOldest)

        var iterator = channel.stream.makeAsyncIterator()
        let received = try await iterator.next()
        guard case .accessUnit(let accessUnit) = received else {
            Issue.record("Expected the newest JPEG access unit")
            channel.finish()
            return
        }
        #expect(accessUnit.sequence == 2)
        #expect(channel.currentStatistics().droppedMessages == 1)
        channel.finish()
    }

    @Test("A negotiated simulator subscription produces validated H.264 access units")
    func negotiatedSyntheticH264Stream() async throws {
        let source = SyntheticVideoDataSource()
        let endpoint = SimulatedRobotEndpoint(
            configuration: .init(
                connectDelay: .zero,
                telemetryInterval: .seconds(10),
                watchdogTimeout: .milliseconds(200)
            ),
            videoDataSource: source
        )
        let session = RobotSession()
        await session.connect(using: endpoint)

        let response = try await session.subscribeVideo(
            VideoSubscriptionRequest(
                cameraID: CameraID(rawValue: "front"),
                preferredCodecs: [.h264],
                constraints: VideoConstraints(
                    maximumWidth: 320,
                    maximumHeight: 180,
                    maximumFramesPerSecond: 15,
                    maximumBitrate: 500_000
                )
            )
        )
        guard case .accepted(let descriptor) = response else {
            Issue.record("Expected the simulator to accept H.264")
            await session.disconnect()
            return
        }
        let snapshot = await session.currentSnapshot()
        let handshake = try #require(snapshot.connection.handshake)
        let dataChannel = try await session.openVideoDataStream(for: descriptor.id)
        let accessUnit = try await firstValidatedAccessUnit(
            in: dataChannel.messages,
            sessionID: handshake.sessionID,
            descriptor: descriptor
        )

        #expect(accessUnit.isKeyFrame)
        #expect(accessUnit.codec == .h264)
        #expect(accessUnit.payload.count > 0)
        #expect(accessUnit.streamID == descriptor.id)

        try await session.unsubscribeVideo(descriptor.id)
        await session.disconnect()
    }

    @Test("Closing a video data stream tears down its producer and finishes the channel")
    func closingDataStreamFinishesChannel() async throws {
        let source = SyntheticVideoDataSource()
        let descriptor = VideoStreamDescriptor(
            id: VideoSubscriptionID(),
            cameraID: CameraID(rawValue: "front"),
            codec: .h264,
            width: 320,
            height: 180,
            framesPerSecond: 15,
            bitrate: 500_000,
            delivery: .quicDatagrams
        )
        let sessionID = UUID()
        let channel = try await source.openVideoDataStream(
            sessionID: sessionID,
            stream: descriptor
        )

        await source.closeVideoDataChannel(channel.id)

        let didFinish = await streamFinishes(channel.messages, timeout: .seconds(2))
        #expect(didFinish)
    }

    @Test("Synthetic encoding honors the negotiated frame rate")
    func syntheticEncodingIsFramePaced() async throws {
        let source = SyntheticVideoDataSource()
        let descriptor = VideoStreamDescriptor(
            id: VideoSubscriptionID(),
            cameraID: CameraID(rawValue: "front"),
            codec: .h264,
            width: 320,
            height: 180,
            framesPerSecond: 20,
            bitrate: 500_000,
            delivery: .quicDatagrams
        )
        let channel = try await source.openVideoDataStream(
            sessionID: UUID(),
            stream: descriptor
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        var accessUnitCount = 0

        for try await message in channel.messages {
            guard case .accessUnit = message else { continue }
            accessUnitCount += 1
            if accessUnitCount == 4 { break }
        }
        let elapsed = startedAt.duration(to: clock.now)
        await source.closeVideoDataChannel(channel.id)

        #expect(elapsed >= .milliseconds(100))
        #expect(elapsed < .seconds(3))
    }

    @Test("The simulator advertises only codecs provided by its injected data source")
    func advertisedCodecsMatchDataSource() async throws {
        let source = SyntheticVideoDataSource()
        let endpoint = SimulatedRobotEndpoint(
            configuration: .init(connectDelay: .zero),
            videoDataSource: source
        )
        let session = RobotSession()
        await session.connect(using: endpoint)

        let snapshot = await session.currentSnapshot()
        let camera = try #require(snapshot.connection.handshake?.capabilities.cameras.first)
        #expect(camera.supportedCodecs == [.h264])

        let response = try await session.subscribeVideo(
            VideoSubscriptionRequest(
                cameraID: camera.id,
                preferredCodecs: [.jpeg]
            )
        )
        guard case .rejected(_, let reason) = response else {
            Issue.record("Expected JPEG-only negotiation to be rejected")
            await session.disconnect()
            return
        }
        #expect(reason == .codecUnavailable)

        let unsupportedDelivery = try await session.subscribeVideo(
            VideoSubscriptionRequest(
                cameraID: camera.id,
                preferredCodecs: [.h264],
                delivery: .reliableStream
            )
        )
        guard case .rejected(_, let deliveryReason) = unsupportedDelivery else {
            Issue.record("Expected reliable delivery to be rejected by the lossy source")
            await session.disconnect()
            return
        }
        #expect(deliveryReason == .deliveryUnavailable)

        let clampedBitrate = try await session.subscribeVideo(
            VideoSubscriptionRequest(
                cameraID: camera.id,
                preferredCodecs: [.h264],
                constraints: VideoConstraints(maximumBitrate: 50_000_000),
                delivery: .quicDatagrams
            )
        )
        guard case .accepted(let descriptor) = clampedBitrate else {
            Issue.record("Expected the supported delivery mode to be accepted")
            await session.disconnect()
            return
        }
        #expect(descriptor.bitrate == source.maximumBitrate)
        try await session.unsubscribeVideo(descriptor.id)
        await session.disconnect()
    }

    @Test("Synthetic allocation rejects oversized stream descriptors before capture starts")
    func oversizedSyntheticDescriptorFailsClosed() async {
        let source = SyntheticVideoDataSource()
        let descriptor = VideoStreamDescriptor(
            id: VideoSubscriptionID(),
            cameraID: CameraID(rawValue: "front"),
            codec: .h264,
            width: 5_000,
            height: 2_000,
            framesPerSecond: 30,
            bitrate: 1_000_000,
            delivery: .quicDatagrams
        )

        do {
            _ = try await source.openVideoDataStream(sessionID: UUID(), stream: descriptor)
            Issue.record("Expected oversized decoded dimensions to be rejected")
        } catch let error as VideoDataValidationError {
            #expect(error == .invalidStreamDescriptor)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A superseded channel token cannot close its replacement")
    func staleChannelCloseDoesNotAffectReplacement() async throws {
        let source = SyntheticVideoDataSource()
        let sessionID = UUID()
        let descriptor = VideoStreamDescriptor(
            id: VideoSubscriptionID(),
            cameraID: CameraID(rawValue: "front"),
            codec: .h264,
            width: 320,
            height: 180,
            framesPerSecond: 15,
            bitrate: 500_000,
            delivery: .quicDatagrams
        )
        let staleChannel = try await source.openVideoDataStream(
            sessionID: sessionID,
            stream: descriptor
        )
        let replacement = try await source.openVideoDataStream(
            sessionID: sessionID,
            stream: descriptor
        )

        await source.closeVideoDataChannel(staleChannel.id)
        let accessUnit = try await firstValidatedAccessUnit(
            in: replacement.messages,
            sessionID: sessionID,
            descriptor: descriptor
        )
        #expect(accessUnit.isKeyFrame)
        await source.closeVideoDataChannel(replacement.id)
    }

    @Test("Duplicate active subscription IDs are rejected without replacing control state")
    func duplicateSubscriptionIDsAreRejected() async throws {
        let endpoint = SimulatedRobotEndpoint(
            configuration: .init(connectDelay: .zero),
            videoDataSource: SyntheticVideoDataSource()
        )
        let session = RobotSession()
        await session.connect(using: endpoint)
        let id = VideoSubscriptionID()
        let request = VideoSubscriptionRequest(
            id: id,
            cameraID: CameraID(rawValue: "front"),
            preferredCodecs: [.h264]
        )

        _ = try await session.subscribeVideo(request)
        do {
            _ = try await session.subscribeVideo(request)
            Issue.record("Expected the duplicate subscription ID to be rejected")
        } catch let error as VideoSubscriptionError {
            #expect(error == .duplicateID(id))
        }
        let snapshot = await session.currentSnapshot()
        #expect(snapshot.videoStreams.filter { $0.id == id }.count == 1)
        try await session.unsubscribeVideo(id)
        await session.disconnect()
    }

    @Test("A stream that finishes opening after disconnect is closed and rejected as stale")
    func staleOpenCannotEscapeDisconnect() async throws {
        let source = SuspendedVideoDataSource()
        let endpoint = SimulatedRobotEndpoint(
            configuration: .init(connectDelay: .zero),
            videoDataSource: source
        )
        let session = RobotSession()
        await session.connect(using: endpoint)
        let response = try await session.subscribeVideo(
            VideoSubscriptionRequest(
                cameraID: CameraID(rawValue: "front"),
                preferredCodecs: [.h264]
            )
        )
        guard case .accepted(let descriptor) = response else {
            Issue.record("Expected H.264 negotiation to succeed")
            return
        }

        let openTask = Task {
            try await session.openVideoDataStream(for: descriptor.id)
        }
        await source.waitUntilOpenBegins()
        await session.disconnect()
        await source.resumeOpen()

        do {
            _ = try await openTask.value
            Issue.record("Expected an opening channel from the old session to be rejected")
        } catch let error as VideoDataTransportError {
            #expect(error == .inactiveSession)
        }
        #expect(await source.closedChannelCount() == 1)
    }

    private func jpegMessage(sequence: UInt64) throws -> VideoDataMessage {
        .accessUnit(
            try EncodedVideoAccessUnit(
                sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                streamID: VideoSubscriptionID(
                    rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
                ),
                codec: .jpeg,
                sequence: sequence,
                captureTimestampUnixMilliseconds: 0,
                presentationTimestamp: Int64(sequence),
                duration: 1,
                timescale: 1,
                isKeyFrame: true,
                codecConfigurationGeneration: nil,
                payload: Data([0xFF, 0xD8, 0xFF, 0xD9])
            )
        )
    }

    private func firstValidatedAccessUnit(
        in stream: RobotVideoDataStream,
        sessionID: UUID,
        descriptor: VideoStreamDescriptor
    ) async throws -> EncodedVideoAccessUnit {
        try await withThrowingTaskGroup(of: EncodedVideoAccessUnit.self) { group in
            group.addTask {
                var validator = VideoStreamValidator(
                    sessionID: sessionID,
                    stream: descriptor
                )
                for try await message in stream {
                    if let accessUnit = try validator.accept(message) {
                        return accessUnit
                    }
                }
                throw PipelineTestError.streamEnded
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(3))
                throw PipelineTestError.timedOut
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func streamFinishes(
        _ stream: RobotVideoDataStream,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    for try await _ in stream {}
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: timeout)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private enum PipelineTestError: Error {
    case streamEnded
    case timedOut
}

private actor SuspendedVideoDataSource: RobotVideoDataSource {
    nonisolated let supportedCodecs: Set<VideoCodec> = [.h264]
    nonisolated let supportedDeliveryModes: Set<VideoDeliveryMode> = [.quicDatagrams]
    nonisolated let maximumBitrate: UInt32 = 8_000_000

    private struct OpenChannel {
        let sessionID: UUID
        let subscriptionID: VideoSubscriptionID
        let channel: BoundedInMemoryVideoChannel
    }

    private var openGate: CheckedContinuation<Void, Never>?
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var didBeginOpen = false
    private var channels: [UUID: OpenChannel] = [:]
    private var closedChannels = 0

    func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) async throws -> RobotVideoDataChannel {
        didBeginOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            openGate = continuation
        }

        let channelID = UUID()
        let channel = try BoundedInMemoryVideoChannel()
        channels[channelID] = OpenChannel(
            sessionID: sessionID,
            subscriptionID: stream.id,
            channel: channel
        )
        return RobotVideoDataChannel(
            id: channelID,
            sessionID: sessionID,
            descriptor: stream,
            messages: channel.stream
        )
    }

    func waitUntilOpenBegins() async {
        if didBeginOpen { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func resumeOpen() {
        openGate?.resume()
        openGate = nil
    }

    func closeVideoDataChannel(_ id: UUID) {
        guard let openChannel = channels.removeValue(forKey: id) else { return }
        openChannel.channel.finish()
        closedChannels += 1
    }

    func closeVideoDataStreams(
        sessionID: UUID,
        subscriptionID: VideoSubscriptionID
    ) {
        closeChannels { channel in
            channel.sessionID == sessionID && channel.subscriptionID == subscriptionID
        }
    }

    func closeAllVideoDataStreams(sessionID: UUID) {
        closeChannels { $0.sessionID == sessionID }
    }

    func handleVideoFeedback(_: VideoReceiverFeedback, sessionID _: UUID) {}

    func closedChannelCount() -> Int {
        closedChannels
    }

    private func closeChannels(where predicate: (OpenChannel) -> Bool) {
        let ids = channels.compactMap { id, channel in
            predicate(channel) ? id : nil
        }
        for id in ids {
            closeVideoDataChannel(id)
        }
    }
}

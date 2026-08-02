import Foundation
import Testing

@testable import ROBControlCore

@Suite("Simulated robot endpoint")
struct SimulatedRobotEndpointTests {
    @Test("Connect and disconnect expose coherent session state")
    func sessionConnectionLifecycle() async {
        let endpoint = makeEndpoint()
        let session = RobotSession(
            configuration: .init(
                commandInterval: .milliseconds(20),
                inputTimeout: .milliseconds(100),
                commandLeaseMilliseconds: 100
            )
        )

        await session.connect(using: endpoint)
        let connected = await session.currentSnapshot()
        #expect(connected.connection.isReady)
        #expect(connected.connection.handshake?.robotName == "Test ROB")

        await session.disconnect()
        let disconnected = await session.currentSnapshot()
        #expect(disconnected.connection.phase == .disconnected)
        #expect(disconnected.telemetry == nil)
    }

    @Test("An endpoint without a video source does not advertise cameras")
    func noVideoSourceMeansNoCameraCapability() async throws {
        let endpoint = SimulatedRobotEndpoint(
            configuration: .init(connectDelay: .zero)
        )
        let handshake = try await endpoint.connect()
        #expect(handshake.capabilities.cameras.isEmpty)
        await endpoint.disconnect()
    }

    @Test("Concurrent endpoint connects produce only one active session")
    func concurrentConnectsAreSerialized() async {
        let endpoint = SimulatedRobotEndpoint(
            configuration: .init(connectDelay: .milliseconds(30)),
            videoDataSource: TestVideoDataSource()
        )
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await endpoint.connect()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await succeeded in group where succeeded {
                count += 1
            }
            return count
        }

        #expect(successes == 1)
        await endpoint.disconnect()
    }

    @Test("Overlapping disconnect calls cannot clobber a later reconnect")
    func concurrentDisconnectsAreCoalesced() async throws {
        let source = TestVideoDataSource(cleanupDelay: .milliseconds(80))
        let endpoint = SimulatedRobotEndpoint(
            configuration: .init(connectDelay: .zero),
            videoDataSource: source
        )
        let session = RobotSession()
        await session.connect(using: endpoint)

        let firstDisconnect = Task { await session.disconnect() }
        try await ContinuousClock().sleep(for: .milliseconds(5))
        let secondDisconnect = Task { await session.disconnect() }
        await secondDisconnect.value
        await firstDisconnect.value

        await session.connect(using: endpoint)
        try await ContinuousClock().sleep(for: .milliseconds(100))
        let snapshot = await session.currentSnapshot()
        #expect(snapshot.connection.isReady)
        await session.disconnect()
    }

    @Test("A late accepted response is unsubscribed after caller cancellation")
    func cancelledSubscriptionCannotBecomeOrphaned() async throws {
        let transport = DelayedVideoResponseTransport()
        let session = RobotSession()
        await session.connect(using: transport)
        let request = VideoSubscriptionRequest(
            cameraID: CameraID(rawValue: "front"),
            preferredCodecs: [.h264]
        )
        let subscriptionTask = Task {
            try await session.subscribeVideo(request)
        }

        await transport.waitUntilSubscribeBegins()
        subscriptionTask.cancel()
        do {
            _ = try await subscriptionTask.value
            Issue.record("Expected subscription cancellation")
        } catch let error as VideoSubscriptionError {
            #expect(error == .cancelled)
        }

        await transport.releaseSubscribeResponse()
        try await ContinuousClock().sleep(for: .milliseconds(20))
        let snapshot = await session.currentSnapshot()
        #expect(snapshot.videoStreams.isEmpty)
        #expect(await transport.didReceiveUnsubscribe(for: request.id))
        await session.disconnect()
    }

    @Test("A video-service failure leaves the control session connected")
    func videoFailureDoesNotDisconnectControl() async throws {
        let transport = FailingVideoTransport()
        let session = RobotSession()
        await session.connect(using: transport)

        do {
            _ = try await session.subscribeVideo(
                VideoSubscriptionRequest(cameraID: CameraID(rawValue: "front"))
            )
            Issue.record("Expected the video service to reject the request")
        } catch let error as FailingVideoTransport.Failure {
            #expect(error == .unavailable)
        }

        let snapshot = await session.currentSnapshot()
        #expect(snapshot.connection.isReady)
        #expect(snapshot.videoStreams.isEmpty)
        await session.disconnect()
    }

    @Test("Video negotiation clamps the requested profile to camera capabilities")
    func videoNegotiation() async throws {
        let endpoint = makeEndpoint()
        let events = await endpoint.events()
        let handshake = try await endpoint.connect()

        let request = VideoSubscriptionRequest(
            cameraID: CameraID(rawValue: "front"),
            preferredCodecs: [.hevc, .h264],
            constraints: VideoConstraints(
                maximumWidth: 4_000,
                maximumHeight: 3_000,
                maximumFramesPerSecond: 60,
                maximumBitrate: 4_000_000
            )
        )
        try await endpoint.send(
            RobotCommandEnvelope(
                sessionID: handshake.sessionID,
                sequence: 1,
                command: .video(.subscribe(request))
            )
        )

        let event = await firstEvent(in: events, timeout: .seconds(1)) { event in
            if case .video(.subscription) = event { return true }
            return false
        }
        guard case .video(.subscription(.accepted(let stream))) = event else {
            Issue.record("Expected an accepted video subscription")
            await endpoint.disconnect()
            return
        }

        #expect(stream.codec == .h264)
        #expect(stream.width == 1_920)
        #expect(stream.height == 1_080)
        #expect(stream.framesPerSecond == 30)
        await endpoint.disconnect()
    }

    @Test("The simulated robot enforces a receive-side motion watchdog")
    func receiveSideWatchdog() async throws {
        let endpoint = makeEndpoint(watchdogTimeout: .milliseconds(60))
        let events = await endpoint.events()
        let handshake = try await endpoint.connect()

        try await endpoint.send(
            RobotCommandEnvelope(
                sessionID: handshake.sessionID,
                sequence: 1,
                command: .setArmed(true)
            )
        )
        try await endpoint.send(
            RobotCommandEnvelope(
                sessionID: handshake.sessionID,
                sequence: 2,
                leaseMilliseconds: 500,
                command: .drive(MotionVector(linear: 1, angular: 0))
            )
        )

        let event = await firstEvent(in: events, timeout: .seconds(1)) { event in
            event == .safety(.motionStopped(.robotWatchdog))
        }

        #expect(event == .safety(.motionStopped(.robotWatchdog)))
        await endpoint.disconnect()
    }

    @Test("Armed fresh input produces leased motion decisions")
    func armedInputProducesMotion() async {
        let endpoint = makeEndpoint(watchdogTimeout: .milliseconds(200))
        let session = RobotSession(
            configuration: .init(
                commandInterval: .milliseconds(20),
                inputTimeout: .milliseconds(100),
                commandLeaseMilliseconds: 100
            )
        )
        await session.connect(using: endpoint)
        await session.setArmed(true)
        await session.updateOperatorInput(
            OperatorControlSample(
                sequence: 1,
                source: .testHarness,
                linear: 0.6,
                angular: 0.1,
                deadManIsHeld: true
            )
        )
        try? await ContinuousClock().sleep(for: .milliseconds(45))

        let snapshot = await session.currentSnapshot()
        #expect(snapshot.connection.isReady)
        #expect(snapshot.safety.isArmed)
        #expect(snapshot.safety.inhibitReason == nil)
        #expect(snapshot.safety.lastCommandSequence != nil)
        await session.disconnect()
        let disconnected = await session.currentSnapshot()
        #expect(!disconnected.safety.isArmed)
    }

    @Test("Session subscription awaits the correlated negotiation response")
    func sessionAwaitsVideoNegotiation() async throws {
        let endpoint = makeEndpoint()
        let session = RobotSession()
        await session.connect(using: endpoint)

        let response = try await session.subscribeVideo(
            VideoSubscriptionRequest(cameraID: CameraID(rawValue: "front"))
        )
        guard case .accepted(let stream) = response else {
            Issue.record("Expected an accepted subscription response")
            await session.disconnect()
            return
        }

        #expect(stream.cameraID == CameraID(rawValue: "front"))
        let snapshot = await session.currentSnapshot()
        #expect(snapshot.videoStreams.contains(where: { $0.id == stream.id }))
        await session.disconnect()
    }

    @Test("Commands from an earlier session are rejected")
    func staleSessionIsRejected() async throws {
        let endpoint = makeEndpoint()
        _ = try await endpoint.connect()

        do {
            try await endpoint.send(
                RobotCommandEnvelope(
                    sessionID: UUID(),
                    sequence: 1,
                    command: .setArmed(true)
                )
            )
            Issue.record("Expected the stale session command to be rejected")
        } catch let error as RobotTransportError {
            guard case .invalidState = error else {
                Issue.record("Unexpected transport error: \(error)")
                await endpoint.disconnect()
                return
            }
        }
        await endpoint.disconnect()
    }

    @Test("Robot-side emergency stop survives reconnect")
    func emergencyStopSurvivesReconnect() async throws {
        let endpoint = makeEndpoint()
        let firstHandshake = try await endpoint.connect()
        try await endpoint.send(
            RobotCommandEnvelope(
                sessionID: firstHandshake.sessionID,
                sequence: 1,
                command: .emergencyStop
            )
        )
        await endpoint.disconnect()

        let secondHandshake = try await endpoint.connect()
        #expect(secondHandshake.safetyState.emergencyStopIsLatched)
        #expect(!secondHandshake.safetyState.isArmed)
        await endpoint.disconnect()
    }

    @Test("Reconnect creates a fresh event channel")
    func reconnectRestoresEvents() async throws {
        let endpoint = makeEndpoint(telemetryInterval: .milliseconds(20))
        let session = RobotSession()

        await session.connect(using: endpoint)
        await session.disconnect()
        await session.connect(using: endpoint)

        let response = try await session.subscribeVideo(
            VideoSubscriptionRequest(cameraID: CameraID(rawValue: "front"))
        )
        guard case .accepted = response else {
            Issue.record("Expected video negotiation to succeed after reconnect")
            await session.disconnect()
            return
        }

        try? await ContinuousClock().sleep(for: .milliseconds(50))
        let snapshot = await session.currentSnapshot()
        #expect(snapshot.connection.isReady)
        #expect(snapshot.telemetry != nil)
        #expect(!snapshot.videoStreams.isEmpty)
        await session.disconnect()
    }

    private func makeEndpoint(
        watchdogTimeout: Duration = .milliseconds(200),
        telemetryInterval: Duration = .seconds(10)
    ) -> SimulatedRobotEndpoint {
        SimulatedRobotEndpoint(
            descriptor: RobotEndpointDescriptor(name: "Test ROB", transport: .simulated),
            configuration: .init(
                connectDelay: .zero,
                telemetryInterval: telemetryInterval,
                watchdogTimeout: watchdogTimeout,
                cameras: [
                    CameraDescriptor(
                        id: CameraID(rawValue: "front"),
                        name: "Front Camera",
                        supportedCodecs: [.h264, .jpeg],
                        maximumWidth: 1_920,
                        maximumHeight: 1_080,
                        maximumFramesPerSecond: 30
                    )
                ]
            ),
            videoDataSource: TestVideoDataSource()
        )
    }

    private func firstEvent(
        in stream: AsyncStream<RobotEvent>,
        timeout: Duration,
        matching predicate: @escaping @Sendable (RobotEvent) -> Bool
    ) async -> RobotEvent? {
        await withTaskGroup(of: RobotEvent?.self) { group in
            group.addTask {
                for await event in stream where predicate(event) {
                    return event
                }
                return nil
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: timeout)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

private actor TestVideoDataSource: RobotVideoDataSource {
    nonisolated let supportedCodecs: Set<VideoCodec> = [.h264, .jpeg]
    nonisolated let supportedDeliveryModes: Set<VideoDeliveryMode> = Set(
        VideoDeliveryMode.allCases
    )
    nonisolated let maximumBitrate = VideoDataChannelLimits.hardMaximumBitrate

    private let cleanupDelay: Duration

    private struct ChannelRecord {
        let sessionID: UUID
        let subscriptionID: VideoSubscriptionID
        let continuation: RobotVideoDataStream.Continuation
    }

    private var channels: [UUID: ChannelRecord] = [:]

    init(cleanupDelay: Duration = .zero) {
        self.cleanupDelay = cleanupDelay
    }

    func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) -> RobotVideoDataChannel {
        let id = UUID()
        let pair = RobotVideoDataStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        channels[id] = ChannelRecord(
            sessionID: sessionID,
            subscriptionID: stream.id,
            continuation: pair.continuation
        )
        return RobotVideoDataChannel(
            id: id,
            sessionID: sessionID,
            descriptor: stream,
            messages: pair.stream
        )
    }

    func closeVideoDataChannel(_ id: UUID) {
        channels.removeValue(forKey: id)?.continuation.finish()
    }

    func closeVideoDataStreams(
        sessionID: UUID,
        subscriptionID: VideoSubscriptionID
    ) async {
        await delayCleanupIfNeeded()
        closeChannels {
            $0.sessionID == sessionID && $0.subscriptionID == subscriptionID
        }
    }

    func closeAllVideoDataStreams(sessionID: UUID) async {
        await delayCleanupIfNeeded()
        closeChannels { $0.sessionID == sessionID }
    }

    func handleVideoFeedback(_: VideoReceiverFeedback, sessionID _: UUID) {}

    private func delayCleanupIfNeeded() async {
        guard cleanupDelay > .zero else { return }
        try? await ContinuousClock().sleep(for: cleanupDelay)
    }

    private func closeChannels(where predicate: (ChannelRecord) -> Bool) {
        let ids = channels.compactMap { id, channel in
            predicate(channel) ? id : nil
        }
        for id in ids {
            closeVideoDataChannel(id)
        }
    }
}

private actor DelayedVideoResponseTransport: RobotTransport {
    nonisolated let descriptor = RobotEndpointDescriptor(
        name: "Delayed Video Transport",
        transport: .simulated
    )

    private let sessionID = UUID()
    private var eventContinuation: AsyncStream<RobotEvent>.Continuation?
    private var subscribeGate: CheckedContinuation<Void, Never>?
    private var subscribeWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribeDidBegin = false
    private var unsubscribedIDs: Set<VideoSubscriptionID> = []

    func events() -> AsyncStream<RobotEvent> {
        let pair = AsyncStream<RobotEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        eventContinuation = pair.continuation
        return pair.stream
    }

    func connect() -> RobotHandshake {
        let handshake = RobotHandshake(
            sessionID: sessionID,
            robotName: descriptor.name,
            capabilities: RobotCapabilities(
                cameras: [
                    CameraDescriptor(
                        id: CameraID(rawValue: "front"),
                        name: "Front Camera",
                        supportedCodecs: [.h264],
                        maximumWidth: 1_920,
                        maximumHeight: 1_080,
                        maximumFramesPerSecond: 30
                    )
                ]
            )
        )
        eventContinuation?.yield(.connected(handshake))
        return handshake
    }

    func disconnect() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func send(_ envelope: RobotCommandEnvelope) async throws {
        guard envelope.sessionID == sessionID else { throw RobotTransportError.notConnected }
        switch envelope.command {
        case .video(.subscribe(let request)):
            subscribeDidBegin = true
            let waiters = subscribeWaiters
            subscribeWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                subscribeGate = continuation
            }
            eventContinuation?.yield(
                .video(
                    .subscription(
                        .accepted(
                            VideoStreamDescriptor(
                                id: request.id,
                                cameraID: request.cameraID,
                                codec: .h264,
                                width: 640,
                                height: 360,
                                framesPerSecond: 30,
                                bitrate: 1_000_000,
                                delivery: .quicDatagrams
                            )
                        )
                    )
                )
            )
        case .video(.unsubscribe(let request)):
            unsubscribedIDs.insert(request.id)
            eventContinuation?.yield(.video(.ended(id: request.id, reason: "Cancelled")))
        default:
            break
        }
        eventContinuation?.yield(.commandAcknowledged(envelope.id))
    }

    func waitUntilSubscribeBegins() async {
        if subscribeDidBegin { return }
        await withCheckedContinuation { continuation in
            subscribeWaiters.append(continuation)
        }
    }

    func releaseSubscribeResponse() {
        subscribeGate?.resume()
        subscribeGate = nil
    }

    func didReceiveUnsubscribe(for id: VideoSubscriptionID) -> Bool {
        unsubscribedIDs.contains(id)
    }
}

private actor FailingVideoTransport: RobotTransport {
    enum Failure: Error, Equatable {
        case unavailable
    }

    nonisolated let descriptor = RobotEndpointDescriptor(
        name: "Control with unavailable video",
        transport: .simulated
    )

    private let sessionID = UUID()
    private var eventContinuation: AsyncStream<RobotEvent>.Continuation?

    func events() -> AsyncStream<RobotEvent> {
        let pair = AsyncStream<RobotEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        eventContinuation = pair.continuation
        return pair.stream
    }

    func connect() -> RobotHandshake {
        let handshake = RobotHandshake(
            sessionID: sessionID,
            robotName: descriptor.name,
            capabilities: RobotCapabilities(
                cameras: [
                    CameraDescriptor(
                        id: CameraID(rawValue: "front"),
                        name: "Front Camera",
                        supportedCodecs: [.h264],
                        maximumWidth: 960,
                        maximumHeight: 540,
                        maximumFramesPerSecond: 20
                    )
                ]
            )
        )
        eventContinuation?.yield(.connected(handshake))
        return handshake
    }

    func disconnect() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func send(_ envelope: RobotCommandEnvelope) throws {
        guard envelope.sessionID == sessionID else { throw RobotTransportError.notConnected }
        if case .video(.subscribe) = envelope.command {
            throw Failure.unavailable
        }
        eventContinuation?.yield(.commandAcknowledged(envelope.id))
    }
}

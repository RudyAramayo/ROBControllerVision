import Foundation
@preconcurrency import Network
import ROBControlCore
import Security

public enum ROBVideoClientEvent: Equatable, Sendable {
    case subscriptionResponse(sessionID: UUID, response: VideoSubscriptionResponse)
    case streamEnded(sessionID: UUID, id: VideoSubscriptionID, reason: String)
    case disconnected(reason: String)
}

/// Authenticated `robvideo/1` client and bounded encoded-media data plane.
///
/// A client is deliberately bound to one already-filtered endpoint. The caller must subscribe with
/// the live UUID returned by its separate `robctl/2` connection; Cerebro rejects any stale or
/// foreign session UUID. Only one H.264 reliable-stream subscription may be active at a time.
public actor ROBVideoClient: RobotVideoDataTransport {
    private enum ConnectionPhase {
        case idle
        case connecting
        case awaitingChallenge
        case awaitingAccepted(
            challenge: ROBVideoAuthenticationChallenge,
            proof: ROBVideoAuthenticationProof
        )
        case awaitingCapabilities
        case ready(ROBCerebroVideoCapabilities)
        case stopped
    }

    private struct PendingSubscription {
        let token: UUID
        let sessionID: UUID
        let request: VideoSubscriptionRequest
        let pipe: ROBVideoMessagePipe
        let continuation: CheckedContinuation<VideoSubscriptionResponse, Error>
    }

    private struct ActiveSubscription {
        let sessionID: UUID
        let stream: VideoStreamDescriptor
        let pipe: ROBVideoMessagePipe
        var decoder: ROBVideoBinaryDecoder
        var channelID: UUID?
    }

    private struct EndingSubscription {
        let sessionID: UUID
        let id: VideoSubscriptionID
        var decoder: ROBVideoBinaryDecoder
    }

    private static let authenticationTimeout: Duration = .seconds(5)
    private static let subscriptionTimeout: Duration = .seconds(5)
    private static let sendTimeout: Duration = .seconds(10)

    public nonisolated let credential: ROBCerebroCredential

    private let endpoint: NWEndpoint
    private let connectionQueue = DispatchQueue(
        label: "com.orbitusrobotics.robvideo.v1.vision.connection",
        qos: .userInitiated
    )
    private var connection: NWConnection?
    private var connectionAttemptID: UUID?
    private var connectionContinuation: CheckedContinuation<[CameraDescriptor], Error>?
    private var phase: ConnectionPhase = .idle
    private var isReceiving = false
    private var authenticationTimeoutTask: Task<Void, Never>?
    private var subscriptionTimeoutTask: Task<Void, Never>?
    private var pendingSubscription: PendingSubscription?
    private var activeSubscription: ActiveSubscription?
    private var endingSubscription: EndingSubscription?
    private var lastAutomaticKeyFrameRequestUptime: TimeInterval = 0
    private var subscribers: [UUID: AsyncStream<ROBVideoClientEvent>.Continuation] = [:]

    public init(endpoint: NWEndpoint, credential: ROBCerebroCredential) {
        self.endpoint = endpoint
        self.credential = credential
    }

    deinit {
        authenticationTimeoutTask?.cancel()
        subscriptionTimeoutTask?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connectionContinuation?.resume(throwing: ROBCerebroTransportError.cancelled)
        pendingSubscription?.continuation.resume(
            throwing: ROBCerebroTransportError.cancelled
        )
        pendingSubscription?.pipe.finish(throwing: ROBCerebroTransportError.cancelled)
        activeSubscription?.pipe.finish(throwing: ROBCerebroTransportError.cancelled)
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    public func events() -> AsyncStream<ROBVideoClientEvent> {
        let id = UUID()
        let pair = AsyncStream<ROBVideoClientEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        subscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return pair.stream
    }

    /// Connects, verifies Cerebro's pinned TLS leaf, performs the pairing-secret proof, and waits
    /// for the one-time capability advertisement.
    public func connect() async throws -> [CameraDescriptor] {
        guard connection == nil,
            connectionAttemptID == nil,
            connectionContinuation == nil
        else {
            throw ROBCerebroTransportError.connectionFailed(
                "A Cerebro video connection is already active."
            )
        }
        try validateCredentialForVideo()

        let parameters = try Self.makeClientParameters(credential: credential)
        let connection = NWConnection(to: endpoint, using: parameters)
        let attemptID = UUID()
        self.connection = connection
        connectionAttemptID = attemptID
        phase = .connecting
        isReceiving = false

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectionContinuation = continuation
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard connection != nil else { return }
                    switch state {
                    case .ready:
                        Task { await self?.connectionBecameReady(attemptID: attemptID) }
                    case .failed(let error):
                        let detail = error.localizedDescription
                        Task { await self?.connectionFailed(detail, attemptID: attemptID) }
                    case .cancelled:
                        Task { await self?.connectionWasCancelled(attemptID: attemptID) }
                    case .setup, .preparing, .waiting:
                        break
                    @unknown default:
                        Task {
                            await self?.connectionFailed(
                                "The video connection entered an unknown Network.framework state.",
                                attemptID: attemptID
                            )
                        }
                    }
                }
                connection.start(queue: connectionQueue)
            }
        } onCancel: {
            Task { await self.cancelConnectionAttempt(attemptID) }
        }
    }

    /// Negotiates one stream. Its bounded media queue is installed before the request is sent, so
    /// the accepted stream's codec configuration and first IDR cannot race channel retrieval.
    public func subscribe(
        sessionID: UUID,
        request: VideoSubscriptionRequest
    ) async throws -> VideoSubscriptionResponse {
        guard case .ready(let capabilities) = phase,
            connection != nil,
            connectionAttemptID != nil
        else {
            throw ROBCerebroTransportError.videoUnavailable
        }
        guard pendingSubscription == nil,
            activeSubscription == nil,
            endingSubscription == nil
        else {
            if pendingSubscription?.request.id == request.id
                || activeSubscription?.stream.id == request.id
                || endingSubscription?.id == request.id
            {
                throw VideoSubscriptionError.duplicateID(request.id)
            }
            throw ROBCerebroTransportError.videoUnavailable
        }
        guard let camera = capabilities.cameras.first(where: { $0.id == request.cameraID }),
            camera.supportedCodecs.contains(.h264),
            camera.supportedDeliveryModes.contains(.reliableStream)
        else {
            throw ROBCerebroTransportError.videoUnavailable
        }

        let wireRequest = try ROBVideoWireSubscriptionRequest(
            sessionID: sessionID,
            request: request
        )
        let data = try ROBVideoJSONCodec.encode(wireRequest)
        let token = UUID()
        let pipe = ROBVideoMessagePipe(activeCapacity: 16) { [weak self] in
            Task {
                await self?.mediaConsumerTerminated(
                    sessionID: sessionID,
                    id: request.id
                )
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingSubscription = PendingSubscription(
                    token: token,
                    sessionID: sessionID,
                    request: request,
                    pipe: pipe,
                    continuation: continuation
                )
                armSubscriptionTimeout(token: token)
                Task { [weak self] in
                    await self?.sendPendingSubscription(data, token: token)
                }
            }
        } onCancel: {
            Task { await self.cancelPendingSubscription(token: token) }
        }
    }

    public func unsubscribe(sessionID: UUID, id: VideoSubscriptionID) async throws {
        guard case .ready = phase else {
            throw ROBCerebroTransportError.videoUnavailable
        }
        if endingSubscription?.sessionID == sessionID, endingSubscription?.id == id {
            return
        }
        guard let active = activeSubscription,
            active.sessionID == sessionID,
            active.stream.id == id
        else {
            throw VideoDataTransportError.subscriptionNotFound(id)
        }

        activeSubscription = nil
        endingSubscription = EndingSubscription(
            sessionID: sessionID,
            id: id,
            decoder: active.decoder
        )
        active.pipe.finish()

        do {
            let request = ROBVideoWireUnsubscribeRequest(sessionID: sessionID, id: id)
            try await sendFrame(
                type: .unsubscribe,
                data: ROBVideoJSONCodec.encode(request)
            )
        } catch {
            let transportError = Self.transportError(from: error)
            stopConnection(error: transportError, expectedAttemptID: connectionAttemptID)
            throw transportError
        }
    }

    public func sendFeedback(
        sessionID: UUID,
        feedback: VideoReceiverFeedback
    ) async throws {
        guard case .ready = phase,
            let active = activeSubscription,
            active.sessionID == sessionID,
            active.stream.id == feedback.id
        else {
            throw VideoDataTransportError.subscriptionNotFound(feedback.id)
        }
        let request = ROBVideoWireReceiverFeedback(
            sessionID: sessionID,
            feedback: feedback
        )
        do {
            try await sendFrame(
                type: .feedback,
                data: ROBVideoJSONCodec.encode(request)
            )
        } catch {
            let transportError = Self.transportError(from: error)
            stopConnection(error: transportError, expectedAttemptID: connectionAttemptID)
            throw transportError
        }
    }

    public func openVideoDataStream(
        sessionID: UUID,
        stream: VideoStreamDescriptor
    ) async throws -> RobotVideoDataChannel {
        guard var active = activeSubscription else {
            throw VideoDataTransportError.subscriptionNotFound(stream.id)
        }
        guard active.sessionID == sessionID else {
            throw VideoDataTransportError.inactiveSession
        }
        guard active.stream == stream else {
            throw VideoDataTransportError.channelMetadataMismatch
        }
        guard active.channelID == nil else {
            throw VideoDataTransportError.channelSuperseded
        }

        let channelID = UUID()
        active.channelID = channelID
        active.pipe.activate()
        activeSubscription = active
        return RobotVideoDataChannel(
            id: channelID,
            sessionID: sessionID,
            descriptor: stream,
            messages: active.pipe.stream
        )
    }

    public func closeVideoDataChannel(_ id: UUID) async {
        guard let active = activeSubscription, active.channelID == id else { return }
        do {
            try await unsubscribe(sessionID: active.sessionID, id: active.stream.id)
        } catch {
            // Closing a local channel is idempotent and nonthrowing. A failed unsubscribe has
            // already failed the video connection, which also releases Cerebro's stream.
        }
    }

    public func disconnect() async {
        guard connection != nil || connectionAttemptID != nil else { return }
        stopConnection(error: nil, expectedAttemptID: connectionAttemptID)
    }

    private func validateCredentialForVideo() throws {
        guard credential.isValid else {
            throw ROBCerebroTransportError.invalidPairingCode
        }
        guard credential.effectiveRole == .operatorController else {
            throw ROBCerebroTransportError.authorizationFailed
        }
    }

    private static func makeClientParameters(
        credential: ROBCerebroCredential
    ) throws -> NWParameters {
        guard credential.isValid else {
            throw ROBCerebroTransportError.invalidPairingCode
        }
        let quic = NWProtocolQUIC.Options(alpn: [ROBCerebroVideoProtocol.applicationProtocol])
        quic.direction = .bidirectional
        quic.idleTimeout = 10_000
        let securityOptions = quic.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
        ROBCerebroPinnedTLS.installExactLeafPin(
            credential.certificateSHA256,
            on: securityOptions
        )

        let parameters = NWParameters(quic: quic)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: ROBVideoFramer.definition),
            at: 0
        )
        return parameters
    }

    private func connectionBecameReady(attemptID: UUID) {
        guard connectionAttemptID == attemptID,
            let connection,
            case .connecting = phase
        else {
            return
        }
        // Cerebro advertises the video service at app connection time, but the operator may not
        // press "Start Video" immediately. Transport-level QUIC PINGs keep the authenticated,
        // otherwise-idle media connection inside both peers' 10-second idle-timeout window without
        // inventing an application message that the server would reject before subscription.
        if let quicMetadata = connection.metadata(definition: NWProtocolQUIC.definition)
            as? NWProtocolQUIC.Metadata
        {
            quicMetadata.keepAlive = .seconds(5)
        }
        phase = .awaitingChallenge
        armAuthenticationTimeout(attemptID: attemptID)
        receiveNextMessage(attemptID: attemptID)
    }

    private func connectionFailed(_ detail: String, attemptID: UUID) {
        stopConnection(
            error: .connectionFailed(detail),
            expectedAttemptID: attemptID
        )
    }

    private func connectionWasCancelled(attemptID: UUID) {
        guard connectionAttemptID == attemptID else { return }
        stopConnection(error: nil, expectedAttemptID: attemptID)
    }

    private func armAuthenticationTimeout(attemptID: UUID) {
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: Self.authenticationTimeout)
            } catch {
                return
            }
            await self?.authenticationTimedOut(attemptID: attemptID)
        }
    }

    private func authenticationTimedOut(attemptID: UUID) {
        guard connectionAttemptID == attemptID else { return }
        stopConnection(error: .timedOut, expectedAttemptID: attemptID)
    }

    private func receiveNextMessage(attemptID: UUID) {
        guard connectionAttemptID == attemptID,
            let connection,
            !isReceiving,
            !isStopped
        else {
            return
        }
        isReceiving = true
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard connection != nil else { return }
            let type =
                (context?.protocolMetadata(definition: ROBVideoFramer.definition)
                as? NWProtocolFramer.Message)?.robVideoMessageType
            let errorDescription = error?.localizedDescription
            Task {
                await self?.received(
                    data: data,
                    type: type,
                    errorDescription: errorDescription,
                    attemptID: attemptID
                )
            }
        }
    }

    private var isStopped: Bool {
        if case .stopped = phase { return true }
        return false
    }

    private func received(
        data: Data?,
        type: ROBVideoMessageType?,
        errorDescription: String?,
        attemptID: UUID
    ) async {
        guard connectionAttemptID == attemptID else { return }
        isReceiving = false

        if let errorDescription {
            stopConnection(
                error: .connectionFailed(errorDescription),
                expectedAttemptID: attemptID
            )
            return
        }
        guard let data, let type, type != .invalid else {
            stopConnection(error: .invalidWireMessage, expectedAttemptID: attemptID)
            return
        }

        do {
            switch phase {
            case .awaitingChallenge:
                guard type == .authenticationChallenge else {
                    throw ROBCerebroTransportError.authenticationFailed
                }
                let challenge = try ROBVideoAuthenticationChallenge(data)
                let proof = try ROBVideoAuthenticator.makeProof(
                    challenge: challenge,
                    credential: credential
                )
                phase = .awaitingAccepted(challenge: challenge, proof: proof)
                try await sendFrame(type: .authenticationProof, data: proof.encoded)

            case .awaitingAccepted(let challenge, let proof):
                guard type == .authenticationAccepted else {
                    throw ROBCerebroTransportError.authenticationFailed
                }
                let accepted = try ROBVideoAuthenticationAccepted(data)
                guard
                    ROBVideoAuthenticator.validate(
                        accepted,
                        proof: proof,
                        challenge: challenge,
                        credential: credential
                    )
                else {
                    throw ROBCerebroTransportError.authenticationFailed
                }
                phase = .awaitingCapabilities

            case .awaitingCapabilities:
                guard type == .capabilities else {
                    throw ROBCerebroTransportError.invalidWireMessage
                }
                let capabilities = try ROBVideoJSONCodec.decode(
                    ROBVideoWireCapabilities.self,
                    from: data
                ).mapped()
                authenticationTimeoutTask?.cancel()
                authenticationTimeoutTask = nil
                phase = .ready(capabilities)
                let continuation = connectionContinuation
                connectionContinuation = nil
                continuation?.resume(returning: capabilities.cameraDescriptors)

            case .ready:
                try handleApplicationMessage(type: type, data: data)

            case .idle, .connecting, .stopped:
                throw ROBCerebroTransportError.invalidWireMessage
            }
        } catch {
            let transportError = Self.transportError(from: error)
            stopConnection(error: transportError, expectedAttemptID: attemptID)
            return
        }

        guard connectionAttemptID == attemptID else { return }
        receiveNextMessage(attemptID: attemptID)
    }

    private func handleApplicationMessage(type: ROBVideoMessageType, data: Data) throws {
        switch type {
        case .subscriptionResponse:
            try handleSubscriptionResponse(data)
        case .codecConfiguration, .accessUnit:
            try handleMediaMessage(type: type, data: data)
        case .streamEnded:
            try handleStreamEnded(data)
        case .authenticationChallenge,
            .authenticationProof,
            .authenticationAccepted,
            .authenticationRejected,
            .capabilities,
            .subscribe,
            .unsubscribe,
            .feedback,
            .invalid:
            throw ROBCerebroTransportError.invalidWireMessage
        }
    }

    private func handleSubscriptionResponse(_ data: Data) throws {
        let mapped = try ROBVideoJSONCodec.decode(
            ROBVideoWireSubscriptionResponse.self,
            from: data
        ).mapped()
        guard let pending = pendingSubscription,
            mapped.sessionID == pending.sessionID,
            mapped.response.subscriptionID == pending.request.id
        else {
            throw ROBCerebroTransportError.invalidWireMessage
        }

        switch mapped.response {
        case .accepted(let stream):
            guard stream.cameraID == pending.request.cameraID,
                pending.request.preferredCodecs.contains(stream.codec),
                stream.width <= pending.request.constraints.maximumWidth,
                stream.height <= pending.request.constraints.maximumHeight,
                stream.framesPerSecond <= pending.request.constraints.maximumFramesPerSecond,
                stream.bitrate <= pending.request.constraints.maximumBitrate,
                stream.delivery == pending.request.delivery
            else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            let decoder = try ROBVideoBinaryDecoder(
                sessionID: pending.sessionID,
                stream: stream
            )
            activeSubscription = ActiveSubscription(
                sessionID: pending.sessionID,
                stream: stream,
                pipe: pending.pipe,
                decoder: decoder,
                channelID: nil
            )
            lastAutomaticKeyFrameRequestUptime = 0

        case .rejected:
            pending.pipe.finish()
        }

        pendingSubscription = nil
        subscriptionTimeoutTask?.cancel()
        subscriptionTimeoutTask = nil
        publish(
            .subscriptionResponse(
                sessionID: mapped.sessionID,
                response: mapped.response
            ))
        pending.continuation.resume(returning: mapped.response)
    }

    private func handleMediaMessage(type: ROBVideoMessageType, data: Data) throws {
        if var active = activeSubscription {
            let message = try active.decoder.decode(data)
            try validateOuterMediaType(type, contains: message)
            let result = active.pipe.offer(message)
            activeSubscription = active
            if result == .droppedOldest {
                requestAutomaticKeyFrame(sessionID: active.sessionID, id: active.stream.id)
            } else if result == .terminated, let channelID = active.channelID {
                Task { [weak self] in await self?.closeVideoDataChannel(channelID) }
            }
            return
        }

        if var ending = endingSubscription {
            let message = try ending.decoder.decode(data)
            try validateOuterMediaType(type, contains: message)
            endingSubscription = ending
            return
        }
        throw ROBCerebroTransportError.invalidWireMessage
    }

    private func validateOuterMediaType(
        _ type: ROBVideoMessageType,
        contains message: VideoDataMessage
    ) throws {
        switch (type, message) {
        case (.codecConfiguration, .codecConfiguration),
            (.accessUnit, .accessUnit):
            return
        default:
            throw ROBCerebroTransportError.invalidWireMessage
        }
    }

    private func handleStreamEnded(_ data: Data) throws {
        let ended = try ROBVideoJSONCodec.decode(ROBVideoWireStreamEnded.self, from: data)
        let id = VideoSubscriptionID(rawValue: ended.id)

        if let active = activeSubscription,
            active.sessionID == ended.sessionID,
            active.stream.id == id
        {
            activeSubscription = nil
            active.pipe.finish()
        } else if endingSubscription?.sessionID == ended.sessionID,
            endingSubscription?.id == id
        {
            endingSubscription = nil
        } else {
            throw ROBCerebroTransportError.invalidWireMessage
        }

        publish(
            .streamEnded(
                sessionID: ended.sessionID,
                id: id,
                reason: ended.reason
            ))
    }

    private func requestAutomaticKeyFrame(sessionID: UUID, id: VideoSubscriptionID) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAutomaticKeyFrameRequestUptime >= 1 else { return }
        lastAutomaticKeyFrameRequestUptime = now
        let feedback = VideoReceiverFeedback(
            id: id,
            estimatedPacketLoss: 0,
            estimatedJitterMilliseconds: 0,
            decodedFramesPerSecond: 0,
            requestsKeyFrame: true
        )
        Task { [weak self] in
            try? await self?.sendFeedback(sessionID: sessionID, feedback: feedback)
        }
    }

    private func mediaConsumerTerminated(sessionID: UUID, id: VideoSubscriptionID) async {
        guard activeSubscription?.sessionID == sessionID,
            activeSubscription?.stream.id == id
        else {
            return
        }
        try? await unsubscribe(sessionID: sessionID, id: id)
    }

    private func sendPendingSubscription(_ data: Data, token: UUID) async {
        guard pendingSubscription?.token == token else { return }
        do {
            try await sendFrame(type: .subscribe, data: data)
        } catch {
            guard pendingSubscription?.token == token else { return }
            stopConnection(
                error: Self.transportError(from: error),
                expectedAttemptID: connectionAttemptID
            )
        }
    }

    private func armSubscriptionTimeout(token: UUID) {
        subscriptionTimeoutTask?.cancel()
        subscriptionTimeoutTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: Self.subscriptionTimeout)
            } catch {
                return
            }
            await self?.subscriptionTimedOut(token: token)
        }
    }

    private func subscriptionTimedOut(token: UUID) {
        guard pendingSubscription?.token == token else { return }
        stopConnection(error: .timedOut, expectedAttemptID: connectionAttemptID)
    }

    private func cancelPendingSubscription(token: UUID) {
        guard pendingSubscription?.token == token else { return }
        stopConnection(error: .cancelled, expectedAttemptID: connectionAttemptID)
    }

    private func sendFrame(type: ROBVideoMessageType, data: Data) async throws {
        guard let connection, connectionAttemptID != nil, !isStopped else {
            throw ROBCerebroTransportError.videoUnavailable
        }
        let limit =
            type.isMedia
            ? ROBCerebroVideoProtocol.maximumFramedPayloadBytes
            : ROBCerebroVideoProtocol.maximumControlMessageBytes
        guard !data.isEmpty, data.count <= limit else {
            throw ROBCerebroTransportError.invalidWireMessage
        }

        let message = NWProtocolFramer.Message(definition: ROBVideoFramer.definition)
        message.robVideoMessageType = type
        let context = NWConnection.ContentContext(
            identifier: "ROBVideo.\(type.rawValue).\(UUID().uuidString)",
            metadata: [message]
        )
        let gate = ROBVideoResultGate<Void>()
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    gate.resolve(
                        .failure(
                            ROBCerebroTransportError.connectionFailed(error.localizedDescription)
                        ))
                } else {
                    gate.resolve(.success(()))
                }
            }
        )

        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(for: Self.sendTimeout)
            } catch {
                return
            }
            gate.resolve(.failure(ROBCerebroTransportError.timedOut))
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: {
            gate.resolve(.failure(ROBCerebroTransportError.cancelled))
        }
    }

    private func cancelConnectionAttempt(_ attemptID: UUID) {
        guard connectionAttemptID == attemptID else { return }
        stopConnection(error: .cancelled, expectedAttemptID: attemptID)
    }

    private func stopConnection(
        error: ROBCerebroTransportError?,
        expectedAttemptID: UUID?
    ) {
        if let expectedAttemptID, connectionAttemptID != expectedAttemptID { return }
        guard connection != nil || connectionAttemptID != nil else { return }

        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil
        subscriptionTimeoutTask?.cancel()
        subscriptionTimeoutTask = nil
        phase = .stopped
        isReceiving = false

        let connection = self.connection
        self.connection = nil
        connectionAttemptID = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()

        let terminalError = error ?? ROBCerebroTransportError.cancelled
        let connectionContinuation = self.connectionContinuation
        self.connectionContinuation = nil
        connectionContinuation?.resume(throwing: terminalError)

        let pending = pendingSubscription
        pendingSubscription = nil
        pending?.pipe.finish(throwing: terminalError)
        pending?.continuation.resume(throwing: terminalError)

        let active = activeSubscription
        activeSubscription = nil
        active?.pipe.finish(throwing: terminalError)
        endingSubscription = nil
        publish(.disconnected(reason: error?.localizedDescription ?? "Cerebro video disconnected."))
    }

    private func publish(_ event: ROBVideoClientEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private static func transportError(from error: Error) -> ROBCerebroTransportError {
        if let transportError = error as? ROBCerebroTransportError {
            return transportError
        }
        if error is CancellationError {
            return .cancelled
        }
        return .connectionFailed(error.localizedDescription)
    }
}

private enum ROBVideoMessagePipeOfferResult {
    case enqueued
    case droppedOldest
    case terminated
}

private final class ROBVideoMessagePipe: @unchecked Sendable {
    let stream: RobotVideoDataStream

    private let continuation: RobotVideoDataStream.Continuation
    private let terminationHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var isTerminated = false
    private var isActive = false
    private var preActivationConfiguration: VideoCodecConfiguration?
    private var preActivationKeyFrame: EncodedVideoAccessUnit?

    init(activeCapacity: Int, terminationHandler: @escaping @Sendable () -> Void) {
        precondition(activeCapacity >= 2)
        let pair = RobotVideoDataStream.makeStream(
            bufferingPolicy: .bufferingNewest(activeCapacity)
        )
        stream = pair.stream
        continuation = pair.continuation
        self.terminationHandler = terminationHandler
        continuation.onTermination = { [weak self] _ in
            self?.markTerminated()
        }
    }

    func offer(_ message: VideoDataMessage) -> ROBVideoMessagePipeOfferResult {
        lock.lock()
        guard !isTerminated else {
            lock.unlock()
            return .terminated
        }
        guard isActive else {
            retainPreActivationMessage(message)
            lock.unlock()
            return .enqueued
        }
        lock.unlock()
        return yield(message)
    }

    /// Opens the consumer-facing side without losing bootstrap state accumulated between the
    /// accepted response and `openVideoDataStream`. Before activation the pipe retains exactly one
    /// configuration and one matching, independently decodable keyframe; predictive frames are
    /// intentionally discarded. This keeps pre-open memory bounded and makes delay duration
    /// irrelevant instead of relying on a three-frame `AsyncThrowingStream` timing window.
    func activate() {
        lock.lock()
        guard !isTerminated, !isActive else {
            lock.unlock()
            return
        }
        isActive = true
        let configuration = preActivationConfiguration
        let keyFrame = preActivationKeyFrame
        preActivationConfiguration = nil
        preActivationKeyFrame = nil
        lock.unlock()

        if let configuration {
            _ = yield(.codecConfiguration(configuration))
        }
        if let keyFrame {
            _ = yield(.accessUnit(keyFrame))
        }
    }

    private func retainPreActivationMessage(_ message: VideoDataMessage) {
        switch message {
        case .codecConfiguration(let configuration):
            preActivationConfiguration = configuration
            // Cerebro sends a configuration immediately before the keyframe that uses it. A new
            // or repeated configuration therefore starts a fresh usable bootstrap pair.
            preActivationKeyFrame = nil

        case .accessUnit(let accessUnit):
            guard accessUnit.isKeyFrame,
                let configuration = preActivationConfiguration,
                accessUnit.sessionID == configuration.sessionID,
                accessUnit.streamID == configuration.streamID,
                accessUnit.codec == configuration.codec,
                accessUnit.codecConfigurationGeneration == configuration.generation
            else {
                return
            }
            preActivationKeyFrame = accessUnit
        }
    }

    private func yield(_ message: VideoDataMessage) -> ROBVideoMessagePipeOfferResult {
        let result = continuation.yield(message)
        switch result {
        case .enqueued:
            return .enqueued
        case .dropped:
            return .droppedOldest
        case .terminated:
            return .terminated
        @unknown default:
            return .terminated
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        lock.lock()
        let wasTerminated = isTerminated
        isTerminated = true
        preActivationConfiguration = nil
        preActivationKeyFrame = nil
        lock.unlock()
        guard !wasTerminated else { return }

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func markTerminated() {
        lock.lock()
        let wasTerminated = isTerminated
        isTerminated = true
        preActivationConfiguration = nil
        preActivationKeyFrame = nil
        lock.unlock()
        if !wasTerminated {
            terminationHandler()
        }
    }
}

private final class ROBVideoResultGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var isResolved = false

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.result = result
            lock.unlock()
        }
    }
}

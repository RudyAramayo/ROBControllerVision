import Foundation
import Network

public enum ROBControlClientState: Equatable, Sendable {
    case disconnected
    case discovering
    case connecting
    case waiting(String)
    case authenticating
    case connected(sessionID: UUID)
    case failed(ROBCerebroTransportError)
}

public enum ROBControlClientEvent: Equatable, Sendable {
    case stateChanged(ROBControlClientState)
    case applicationData(Data)
    case lidarTelemetry(Data)
    case disconnected(ROBCerebroTransportError?)
}

/// Low-level authenticated `robctl/2` client.
///
/// The actor owns exactly one QUIC connection and exposes Cerebro's challenge session bytes as the
/// authoritative UUID. A higher-level `CerebroRobotTransport` must use that UUID when binding a
/// separate `robvideo/1` subscription.
public actor ROBControlClient {
    private enum AuthenticationState {
        case idle
        case awaitingChallenge
        case awaitingAccepted(ROBControlAuthChallenge, ROBControlAuthProof)
        case authenticated(sessionID: UUID)
        case stopped
    }

    private static let authenticationTimeout: Duration = .seconds(5)
    private static let pairingHelloSize = 4_096

    public nonisolated let credential: ROBCerebroCredential

    private let discovery: ROBControlDiscovery
    private let connectionQueue = DispatchQueue(
        label: "com.orbitusrobotics.robctl.v2.vision.connection"
    )
    private var connection: NWConnection?
    private var connectionAttemptID: UUID?
    private var discoveryAttemptID: UUID?
    private var connectionContinuation: CheckedContinuation<UUID, Error>?
    private var authenticationState: AuthenticationState = .idle
    private var authenticationTimeoutTask: Task<Void, Never>?
    private var isReceiving = false
    private var state: ROBControlClientState = .disconnected
    private var subscribers: [UUID: AsyncStream<ROBControlClientEvent>.Continuation] = [:]

    public init(
        credential: ROBCerebroCredential,
        discovery: ROBControlDiscovery = ROBControlDiscovery()
    ) {
        self.credential = credential
        self.discovery = discovery
    }

    deinit {
        authenticationTimeoutTask?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connectionContinuation?.resume(throwing: ROBCerebroTransportError.cancelled)
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    public func events() -> AsyncStream<ROBControlClientEvent> {
        let id = UUID()
        let pair = AsyncStream<ROBControlClientEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        subscribers[id] = pair.continuation
        pair.continuation.yield(.stateChanged(state))
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return pair.stream
    }

    public func currentState() -> ROBControlClientState {
        state
    }

    public func liveSessionID() -> UUID? {
        guard case .authenticated(let sessionID) = authenticationState else { return nil }
        return sessionID
    }

    /// Discovers the exact robot ID named by the installed credential and authenticates to it.
    @discardableResult
    public func connect() async throws -> UUID {
        guard discoveryAttemptID == nil, connectionAttemptID == nil, connection == nil else {
            throw ROBCerebroTransportError.connectionFailed(
                "A Cerebro connection operation is already active."
            )
        }
        try validateCredentialForControl()

        let attemptID = UUID()
        discoveryAttemptID = attemptID
        setState(.discovering)
        let discovered: ROBControlDiscoveredEndpoint
        do {
            discovered = try await discovery.discover(credential: credential)
        } catch {
            guard discoveryAttemptID == attemptID else {
                throw ROBCerebroTransportError.cancelled
            }
            discoveryAttemptID = nil
            let transportError = Self.transportError(from: error)
            setState(.failed(transportError))
            publish(.disconnected(transportError))
            throw transportError
        }
        guard discoveryAttemptID == attemptID else {
            throw ROBCerebroTransportError.cancelled
        }
        discoveryAttemptID = nil
        return try await connect(to: discovered.endpoint)
    }

    /// Connects to an already-filtered Bonjour endpoint. This is also the localhost-test seam.
    @discardableResult
    public func connect(to endpoint: NWEndpoint) async throws -> UUID {
        guard connectionAttemptID == nil, connection == nil else {
            throw ROBCerebroTransportError.connectionFailed(
                "A Cerebro control connection is already active."
            )
        }
        try validateCredentialForControl()

        let parameters = try ROBCerebroPinnedTLS.makeControlClientParameters(
            credential: credential
        )
        let connection = NWConnection(to: endpoint, using: parameters)
        let attemptID = UUID()
        connectionAttemptID = attemptID
        self.connection = connection
        authenticationState = .idle
        isReceiving = false
        setState(.connecting)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectionContinuation = continuation
                connection.stateUpdateHandler = { [weak self, weak connection] newState in
                    guard connection != nil else { return }
                    switch newState {
                    case .ready:
                        Task { await self?.connectionBecameReady(attemptID: attemptID) }
                    case .waiting(let error):
                        let detail = error.localizedDescription
                        Task { await self?.connectionIsWaiting(detail, attemptID: attemptID) }
                    case .failed(let error):
                        let detail = error.localizedDescription
                        Task { await self?.connectionFailed(detail, attemptID: attemptID) }
                    case .cancelled:
                        Task { await self?.connectionWasCancelled(attemptID: attemptID) }
                    case .setup, .preparing:
                        break
                    @unknown default:
                        let detail = "The control connection entered an unknown Network.framework state."
                        Task { await self?.connectionFailed(detail, attemptID: attemptID) }
                    }
                }
                connection.start(queue: connectionQueue)
            }
        } onCancel: {
            Task { await self.cancelConnectionAttempt(attemptID) }
        }
    }

    public func sendApplicationData(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= ROBControlFrameHeader.maximumPayloadLength else {
            throw ROBCerebroTransportError.invalidApplicationPayload
        }
        guard case .authenticated = authenticationState else {
            throw ROBCerebroTransportError.connectionFailed(
                "The control connection is not authenticated."
            )
        }
        try await sendFrame(type: .sendData, data: data)
    }

    public func disconnect() async {
        let discoveryWasActive = discoveryAttemptID != nil
        discoveryAttemptID = nil
        if discoveryWasActive {
            await discovery.cancel()
        }

        guard connection != nil || connectionAttemptID != nil else {
            if state != .disconnected {
                setState(.disconnected)
                publish(.disconnected(nil))
            }
            return
        }
        stopConnection(error: nil, expectedAttemptID: connectionAttemptID)
    }

    private func validateCredentialForControl() throws {
        guard credential.isValid else {
            throw ROBCerebroTransportError.invalidPairingCode
        }
        guard credential.effectiveRole == .operatorController else {
            throw ROBCerebroTransportError.authorizationFailed
        }
    }

    private func connectionBecameReady(attemptID: UUID) async {
        guard connectionAttemptID == attemptID, connection != nil else { return }
        switch authenticationState {
        case .idle:
            authenticationState = .awaitingChallenge
            setState(.authenticating)
            armAuthenticationTimeout(attemptID: attemptID)
            var hello = Data(credential.controllerID.uuidString.lowercased().utf8)
            hello.append(Data(repeating: 0, count: Self.pairingHelloSize - hello.count))
            do {
                try await sendFrame(type: .pairingHello, data: hello)
                guard connectionAttemptID == attemptID else { return }
                receiveNextMessage(attemptID: attemptID)
            } catch {
                stopConnection(
                    error: Self.transportError(from: error),
                    expectedAttemptID: attemptID
                )
            }
        case .authenticated(let sessionID):
            setState(.connected(sessionID: sessionID))
            receiveNextMessage(attemptID: attemptID)
        case .awaitingChallenge, .awaitingAccepted, .stopped:
            break
        }
    }

    private func connectionIsWaiting(_ detail: String, attemptID: UUID) {
        guard connectionAttemptID == attemptID else { return }
        setState(.waiting(detail))
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
                (context?.protocolMetadata(definition: ROBControlV2Framer.definition)
                as? NWProtocolFramer.Message)?.robControlMessageType
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
        if case .stopped = authenticationState { return true }
        return false
    }

    private func received(
        data: Data?,
        type: ROBControlWireMessageType?,
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

        switch authenticationState {
        case .awaitingChallenge:
            guard type == .pairingChallenge,
                let challenge = ROBControlAuthChallenge(data),
                challenge.robotID == credential.robotID
            else {
                stopConnection(error: .authenticationFailed, expectedAttemptID: attemptID)
                return
            }
            do {
                let proof = try ROBControlAuthenticator.makeProof(
                    challenge: challenge,
                    credential: credential
                )
                authenticationState = .awaitingAccepted(challenge, proof)
                try await sendFrame(type: .pairingProof, data: proof.encoded)
                guard connectionAttemptID == attemptID else { return }
                receiveNextMessage(attemptID: attemptID)
            } catch {
                stopConnection(
                    error: Self.transportError(from: error),
                    expectedAttemptID: attemptID
                )
            }

        case .awaitingAccepted(let challenge, let proof):
            guard type == .pairingAccepted,
                let accepted = ROBControlAuthAccepted(data),
                ROBControlAuthenticator.validate(
                    accepted,
                    proof: proof,
                    challenge: challenge,
                    credential: credential
                ),
                let sessionID = challenge.sessionUUID
            else {
                stopConnection(error: .authenticationFailed, expectedAttemptID: attemptID)
                return
            }
            authenticationTimeoutTask?.cancel()
            authenticationTimeoutTask = nil
            authenticationState = .authenticated(sessionID: sessionID)
            setState(.connected(sessionID: sessionID))
            let continuation = connectionContinuation
            connectionContinuation = nil
            continuation?.resume(returning: sessionID)
            receiveNextMessage(attemptID: attemptID)

        case .authenticated:
            switch type {
            case .sendData:
                guard !data.isEmpty else {
                    stopConnection(error: .invalidWireMessage, expectedAttemptID: attemptID)
                    return
                }
                publish(.applicationData(data))
            case .lidarTelemetry:
                guard !data.isEmpty else {
                    stopConnection(error: .invalidWireMessage, expectedAttemptID: attemptID)
                    return
                }
                publish(.lidarTelemetry(data))
            case .setAutomationScript,
                .pairingChallenge,
                .pairingProof,
                .pairingAccepted,
                .pairingRejected,
                .pairingHello,
                .invalid:
                stopConnection(error: .invalidWireMessage, expectedAttemptID: attemptID)
                return
            }
            receiveNextMessage(attemptID: attemptID)

        case .idle, .stopped:
            stopConnection(error: .invalidWireMessage, expectedAttemptID: attemptID)
        }
    }

    private func sendFrame(type: ROBControlWireMessageType, data: Data) async throws {
        guard let connection, connectionAttemptID != nil, !isStopped else {
            throw ROBCerebroTransportError.connectionFailed(
                "The control connection is not available."
            )
        }
        guard data.count <= ROBControlFrameHeader.maximumPayloadLength else {
            throw ROBCerebroTransportError.invalidApplicationPayload
        }

        let message = NWProtocolFramer.Message(definition: ROBControlV2Framer.definition)
        message.robControlMessageType = type
        let context = NWConnection.ContentContext(
            identifier: "ROBControl.\(type.rawValue).\(UUID().uuidString)",
            metadata: [message]
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: ROBCerebroTransportError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
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
        authenticationState = .stopped
        isReceiving = false

        let connection = self.connection
        self.connection = nil
        connectionAttemptID = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()

        let continuation = connectionContinuation
        connectionContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
            setState(.failed(error))
        } else {
            continuation?.resume(throwing: ROBCerebroTransportError.cancelled)
            setState(.disconnected)
        }
        publish(.disconnected(error))
    }

    private func setState(_ newState: ROBControlClientState) {
        guard state != newState else { return }
        state = newState
        publish(.stateChanged(newState))
    }

    private func publish(_ event: ROBControlClientEvent) {
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

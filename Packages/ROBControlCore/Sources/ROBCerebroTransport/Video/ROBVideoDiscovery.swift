import Foundation
@preconcurrency import Network

/// A Bonjour route that advertised the exact paired Cerebro video service contract.
public struct ROBVideoDiscoveredEndpoint: @unchecked Sendable {
    public let endpoint: NWEndpoint
    public let serviceName: String
    public let robotID: UUID

    public init(endpoint: NWEndpoint, serviceName: String, robotID: UUID) {
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.robotID = robotID
    }
}

/// One-shot, credential-scoped discovery for Cerebro's `robvideo/1` service.
///
/// TXT records are routing hints only. `ROBVideoClient` still authenticates the route with the
/// credential's exact TLS leaf pin and HMAC pairing secret before accepting capabilities.
public actor ROBVideoDiscovery {
    private var browser: NWBrowser?
    private var continuation: CheckedContinuation<ROBVideoDiscoveredEndpoint, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    deinit {
        timeoutTask?.cancel()
        browser?.cancel()
        continuation?.resume(throwing: ROBCerebroTransportError.cancelled)
    }

    public func discover(
        credential: ROBCerebroCredential,
        timeout: Duration = .seconds(8)
    ) async throws -> ROBVideoDiscoveredEndpoint {
        guard credential.isValid else {
            throw ROBCerebroTransportError.invalidPairingCode
        }
        guard credential.effectiveRole == .operatorController else {
            throw ROBCerebroTransportError.authorizationFailed
        }
        guard browser == nil, continuation == nil else {
            throw ROBCerebroTransportError.discoveryFailed(
                "A Cerebro video discovery operation is already active."
            )
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                startBrowser(credential: credential, timeout: timeout)
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    public func cancel() {
        finish(.failure(ROBCerebroTransportError.cancelled))
    }

    private func startBrowser(credential: ROBCerebroCredential, timeout: Duration) {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: ROBCerebroVideoProtocol.serviceType, domain: nil),
            using: parameters
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard browser != nil else { return }
            switch state {
            case .failed(let error):
                let detail = error.localizedDescription
                Task {
                    await self?.finish(
                        .failure(ROBCerebroTransportError.discoveryFailed(detail))
                    )
                }
            case .cancelled:
                Task { await self?.browserWasCancelled(browser) }
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let browser else { return }
            let selected =
                results
                .filter { Self.matches($0, credential: credential) }
                .sorted { $0.endpoint.debugDescription < $1.endpoint.debugDescription }
                .first
            guard let selected else { return }

            let serviceName: String
            if case .service(let name, _, _, _) = selected.endpoint {
                serviceName = name
            } else {
                serviceName = selected.endpoint.debugDescription
            }
            let discovered = ROBVideoDiscoveredEndpoint(
                endpoint: selected.endpoint,
                serviceName: serviceName,
                robotID: credential.robotID
            )
            Task { await self?.found(discovered, browser: browser) }
        }

        timeoutTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: timeout)
            } catch {
                return
            }
            await self?.finish(.failure(ROBCerebroTransportError.timedOut))
        }
        browser.start(
            queue: DispatchQueue(label: "com.orbitusrobotics.robvideo.v1.vision.browse")
        )
    }

    private nonisolated static func matches(
        _ result: NWBrowser.Result,
        credential: ROBCerebroCredential
    ) -> Bool {
        guard case .bonjour(let txtRecord) = result.metadata,
            let robotIDText = txtRecord["robot_id"],
            UUID(uuidString: robotIDText) == credential.robotID
        else {
            return false
        }
        return txtRecord["ver"] == "1"
            && txtRecord["alpn"] == ROBCerebroVideoProtocol.applicationProtocol
            && txtRecord["codec"] == "h264"
            && txtRecord["delivery"] == "reliableStream"
    }

    private func found(_ endpoint: ROBVideoDiscoveredEndpoint, browser: NWBrowser) {
        guard self.browser === browser else { return }
        finish(.success(endpoint))
    }

    private func browserWasCancelled(_ browser: NWBrowser?) {
        guard let browser, self.browser === browser, continuation != nil else { return }
        finish(.failure(ROBCerebroTransportError.cancelled))
    }

    private func finish(_ result: Result<ROBVideoDiscoveredEndpoint, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        continuation.resume(with: result)
    }
}

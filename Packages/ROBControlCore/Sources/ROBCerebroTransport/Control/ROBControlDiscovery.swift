import Foundation
import Network

public struct ROBControlDiscoveredEndpoint: @unchecked Sendable {
    public let endpoint: NWEndpoint
    public let serviceName: String
    public let robotID: UUID
}

/// One-shot Bonjour discovery for the paired Cerebro control service.
public actor ROBControlDiscovery {
    private var browser: NWBrowser?
    private var continuation: CheckedContinuation<ROBControlDiscoveredEndpoint, Error>?
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
    ) async throws -> ROBControlDiscoveredEndpoint {
        guard credential.isValid else {
            throw ROBCerebroTransportError.invalidPairingCode
        }
        guard credential.effectiveRole == .operatorController else {
            throw ROBCerebroTransportError.authorizationFailed
        }
        guard browser == nil, continuation == nil else {
            throw ROBCerebroTransportError.discoveryFailed(
                "A Cerebro discovery operation is already active."
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
            for: .bonjour(
                type: ROBCerebroPairingStore.controlServiceType,
                domain: nil
            ),
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
                .filter { ROBCerebroPairingStore.result($0, matches: credential) }
                .sorted { $0.endpoint.debugDescription < $1.endpoint.debugDescription }
                .first
            guard let selected else { return }

            let serviceName: String
            if case .service(let name, _, _, _) = selected.endpoint {
                serviceName = name
            } else {
                serviceName = selected.endpoint.debugDescription
            }
            let discovered = ROBControlDiscoveredEndpoint(
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
        browser.start(queue: DispatchQueue(label: "com.orbitusrobotics.robctl.v2.vision.browse"))
    }

    private func found(_ endpoint: ROBControlDiscoveredEndpoint, browser: NWBrowser) {
        guard self.browser === browser else { return }
        finish(.success(endpoint))
    }

    private func browserWasCancelled(_ browser: NWBrowser?) {
        guard let browser, self.browser === browser, continuation != nil else { return }
        finish(.failure(ROBCerebroTransportError.cancelled))
    }

    private func finish(_ result: Result<ROBControlDiscoveredEndpoint, Error>) {
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

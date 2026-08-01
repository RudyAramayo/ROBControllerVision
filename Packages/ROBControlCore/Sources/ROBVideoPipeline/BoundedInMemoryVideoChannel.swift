import Foundation
import ROBControlCore

public enum VideoDataChannelOfferResult: Equatable, Sendable {
    case enqueued
    case droppedOldest
    case terminated
    case rejected(String)
}

public struct VideoDataChannelStatistics: Equatable, Sendable {
    public var offeredMessages: UInt64
    public var droppedMessages: UInt64
    public var isTerminated: Bool

    public init(
        offeredMessages: UInt64 = 0,
        droppedMessages: UInt64 = 0,
        isTerminated: Bool = false
    ) {
        self.offeredMessages = offeredMessages
        self.droppedMessages = droppedMessages
        self.isTerminated = isTerminated
    }
}

/// A nonblocking stand-in for a lossy network video data plane. Its bounded queue deliberately
/// drops stale media instead of applying backpressure to robot control or safety traffic.
public final class BoundedInMemoryVideoChannel: @unchecked Sendable {
    public let stream: RobotVideoDataStream

    private let continuation: RobotVideoDataStream.Continuation
    private let terminationHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var statistics = VideoDataChannelStatistics()

    public init(
        capacity: Int = 3,
        terminationHandler: @escaping @Sendable () -> Void = {}
    ) throws {
        guard capacity > 0 else {
            throw VideoPipelineError.invalidChannelCapacity(capacity)
        }
        let pair = RobotVideoDataStream.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
        self.terminationHandler = terminationHandler
        continuation.onTermination = { [weak self] _ in
            self?.markTerminated()
        }
    }

    @discardableResult
    public func offer(_ message: VideoDataMessage) -> VideoDataChannelOfferResult {
        do {
            try message.validate()
        } catch {
            return .rejected(error.localizedDescription)
        }

        let result = continuation.yield(message)
        lock.lock()
        defer { lock.unlock() }
        statistics.offeredMessages &+= 1

        switch result {
        case .enqueued:
            return .enqueued
        case .dropped:
            statistics.droppedMessages &+= 1
            return .droppedOldest
        case .terminated:
            statistics.isTerminated = true
            return .terminated
        @unknown default:
            statistics.isTerminated = true
            return .terminated
        }
    }

    public func finish(throwing error: (any Error)? = nil) {
        lock.lock()
        let wasTerminated = statistics.isTerminated
        statistics.isTerminated = true
        lock.unlock()

        guard !wasTerminated else { return }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    public func currentStatistics() -> VideoDataChannelStatistics {
        lock.lock()
        defer { lock.unlock() }
        return statistics
    }

    private func markTerminated() {
        lock.lock()
        let wasTerminated = statistics.isTerminated
        statistics.isTerminated = true
        lock.unlock()
        if !wasTerminated {
            terminationHandler()
        }
    }
}

final class VideoProducerTerminationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isTerminated = false

    func requestTermination() {
        lock.lock()
        isTerminated = true
        lock.unlock()
    }

    func terminationWasRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTerminated
    }
}

final class KeyFrameRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isRequested = true

    func request() {
        lock.lock()
        isRequested = true
        lock.unlock()
    }

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let requested = isRequested
        isRequested = false
        return requested
    }
}

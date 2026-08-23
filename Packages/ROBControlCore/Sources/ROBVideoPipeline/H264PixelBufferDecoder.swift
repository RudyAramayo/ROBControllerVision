import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes the receiver's compressed H.264 samples into Metal-compatible pixel buffers.
///
/// This path is independent of `AVSampleBufferVideoRenderer`, whose displayed-pixel-buffer API
/// does not reliably vend a frame when its presentation layer is hidden in an immersive space.
final class H264PixelBufferDecoder {
    typealias OutputHandler = @Sendable (CVPixelBuffer) -> Void
    typealias ErrorHandler = @Sendable (VideoPipelineError) -> Void

    private let outputHandler: OutputHandler
    private let errorHandler: ErrorHandler
    private var decompressionSession: VTDecompressionSession?

    init(
        outputHandler: @escaping OutputHandler,
        errorHandler: @escaping ErrorHandler
    ) {
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
    }

    deinit {
        invalidateSession(waitForFrames: false)
    }

    func decode(_ sampleBuffer: CMSampleBuffer) throws {
        let session = try session(for: sampleBuffer)
        var infoFlags = VTDecodeInfoFlags()
        let outputHandler = outputHandler
        let errorHandler = errorHandler
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { status, flags, imageBuffer, _, _, _ in
            guard status == noErr else {
                errorHandler(.decompressionFailed(status))
                return
            }
            guard !flags.contains(.frameDropped), let imageBuffer else {
                errorHandler(.decompressedFrameDropped)
                return
            }
            outputHandler(imageBuffer)
        }
        guard status == noErr else {
            throw VideoPipelineError.decompressionFailed(status)
        }
        if infoFlags.contains(.frameDropped) {
            errorHandler(.decompressedFrameDropped)
        }
    }

    func reset() {
        invalidateSession(waitForFrames: true)
    }

    private func session(for sampleBuffer: CMSampleBuffer) throws -> VTDecompressionSession {
        if let decompressionSession {
            return decompressionSession
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw VideoPipelineError.missingFormatDescription
        }
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw VideoPipelineError.decompressionSessionCreationFailed(status)
        }
        decompressionSession = newSession
        return newSession
    }

    private func invalidateSession(waitForFrames: Bool) {
        guard let decompressionSession else { return }
        if waitForFrames {
            VTDecompressionSessionFinishDelayedFrames(decompressionSession)
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
        }
        VTDecompressionSessionInvalidate(decompressionSession)
        self.decompressionSession = nil
    }
}

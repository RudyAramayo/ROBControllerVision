import CoreMedia
import CoreVideo
import Foundation
import ROBControlCore
import VideoToolbox

public struct H264EncodedFrame: Sendable {
    public let sequence: UInt64
    public let presentationTimeMicroseconds: Int64
    public let durationMicroseconds: UInt32
    public let isKeyFrame: Bool
    public let parameterSets: [Data]?
    public let nalUnitHeaderLength: UInt8
    public let payload: Data

    public init(
        sequence: UInt64,
        presentationTimeMicroseconds: Int64,
        durationMicroseconds: UInt32,
        isKeyFrame: Bool,
        parameterSets: [Data]?,
        nalUnitHeaderLength: UInt8,
        payload: Data
    ) {
        self.sequence = sequence
        self.presentationTimeMicroseconds = presentationTimeMicroseconds
        self.durationMicroseconds = durationMicroseconds
        self.isKeyFrame = isKeyFrame
        self.parameterSets = parameterSets
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.payload = payload
    }
}

/// A VideoToolbox encoder owned by one isolation domain.
///
/// `H264VideoEncoder` is intentionally not `Sendable`: callers must keep an instance inside one
/// actor (as `SyntheticVideoProducer` does). VideoToolbox invokes the supplied output closure on
/// its own callback queue, and that closure receives only copied, `Sendable` data.
public final class H264VideoEncoder {
    public typealias OutputHandler = @Sendable (Result<H264EncodedFrame, VideoPipelineError>) -> Void

    private let outputHandler: OutputHandler
    private var compressionSession: VTCompressionSession?
    private var lastPresentationTimeMicroseconds: Int64 = -1

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        averageBitrate: Int,
        outputHandler: @escaping OutputHandler
    ) throws {
        guard width > 0,
            height > 0,
            width <= VideoDataChannelLimits.hardMaximumVideoDimension,
            height <= VideoDataChannelLimits.hardMaximumVideoDimension,
            width * height <= VideoDataChannelLimits.hardMaximumDecodedPixels
        else {
            throw VideoPipelineError.invalidDimensions(width: width, height: height)
        }
        guard framesPerSecond > 0,
            framesPerSecond <= VideoDataChannelLimits.hardMaximumFramesPerSecond,
            averageBitrate > 0,
            UInt64(averageBitrate) <= UInt64(VideoDataChannelLimits.hardMaximumBitrate)
        else {
            throw VideoPipelineError.invalidEncoderConfiguration(
                framesPerSecond: framesPerSecond,
                averageBitrate: averageBitrate
            )
        }
        self.outputHandler = outputHandler

        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: imageAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw VideoPipelineError.compressionSessionCreationFailed(status)
        }
        compressionSession = session

        do {
            try setProperty(
                kVTCompressionPropertyKey_RealTime,
                value: kCFBooleanTrue,
                name: "RealTime"
            )
            try setProperty(
                kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse,
                name: "AllowFrameReordering"
            )
            #if !targetEnvironment(simulator)
                try setProperty(
                    kVTCompressionPropertyKey_ProfileLevel,
                    value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
                    name: "ProfileLevel",
                    allowedFailureStatuses: [kVTPropertyNotSupportedErr, kVTParameterErr]
                )
            #endif
            try setProperty(
                kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: framesPerSecond),
                name: "ExpectedFrameRate"
            )
            try setProperty(
                kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: averageBitrate),
                name: "AverageBitRate"
            )
            try setProperty(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: max(1, framesPerSecond)),
                name: "MaxKeyFrameInterval"
            )
        } catch {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
            throw error
        }

        let preparationStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard preparationStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
            throw VideoPipelineError.compressionPreparationFailed(preparationStatus)
        }
    }

    deinit {
        if let compressionSession {
            VTCompressionSessionInvalidate(compressionSession)
        }
    }

    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        sequence: UInt64,
        presentationTimeMicroseconds: Int64,
        durationMicroseconds: UInt32,
        forceKeyFrame: Bool
    ) throws {
        guard let compressionSession else {
            throw VideoPipelineError.channelClosed
        }
        guard presentationTimeMicroseconds > lastPresentationTimeMicroseconds else {
            throw VideoPipelineError.compressionFailed(kVTParameterErr)
        }
        lastPresentationTimeMicroseconds = presentationTimeMicroseconds

        let presentationTime = CMTime(
            value: presentationTimeMicroseconds,
            timescale: 1_000_000
        )
        let duration = CMTime(value: Int64(durationMicroseconds), timescale: 1_000_000)
        let frameProperties: CFDictionary? =
            forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        var infoFlags = VTEncodeInfoFlags()
        let outputHandler = outputHandler
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: &infoFlags
        ) { status, flags, sampleBuffer in
            guard status == noErr else {
                outputHandler(.failure(.compressionFailed(status)))
                return
            }
            if flags.contains(.frameDropped) {
                outputHandler(.failure(.encodedFrameDropped))
                return
            }
            guard let sampleBuffer else {
                outputHandler(.failure(.missingEncodedSample))
                return
            }

            do {
                let frame = try Self.copyEncodedFrame(
                    from: sampleBuffer,
                    sequence: sequence,
                    presentationTimeMicroseconds: presentationTimeMicroseconds,
                    durationMicroseconds: durationMicroseconds
                )
                outputHandler(.success(frame))
            } catch let error as VideoPipelineError {
                outputHandler(.failure(error))
            } catch {
                outputHandler(.failure(.missingEncodedSample))
            }
        }
        guard status == noErr else {
            throw VideoPipelineError.compressionFailed(status)
        }
        if infoFlags.contains(.frameDropped) {
            outputHandler(.failure(.encodedFrameDropped))
        }
    }

    public func finish() {
        guard let compressionSession else { return }
        VTCompressionSessionCompleteFrames(
            compressionSession,
            untilPresentationTimeStamp: .invalid
        )
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
    }

    private func setProperty(
        _ key: CFString,
        value: CFTypeRef,
        name: String,
        allowedFailureStatuses: Set<OSStatus> = []
    ) throws {
        guard let compressionSession else {
            throw VideoPipelineError.channelClosed
        }
        let status = VTSessionSetProperty(compressionSession, key: key, value: value)
        if allowedFailureStatuses.contains(status) {
            return
        }
        guard status == noErr else {
            throw VideoPipelineError.compressionPropertyFailed(name: name, status: status)
        }
    }

    private static func copyEncodedFrame(
        from sampleBuffer: CMSampleBuffer,
        sequence: UInt64,
        presentationTimeMicroseconds: Int64,
        durationMicroseconds: UInt32
    ) throws -> H264EncodedFrame {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw VideoPipelineError.missingDataBuffer
        }
        let payloadLength = CMBlockBufferGetDataLength(dataBuffer)
        var payload = Data(count: payloadLength)
        let copyStatus = payload.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: payloadLength,
                destination: baseAddress
            )
        }
        guard copyStatus == noErr else {
            throw VideoPipelineError.blockBufferCopyFailed(copyStatus)
        }

        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true

        var parameterSets: [Data]?
        var nalUnitHeaderLength: UInt8 = 4
        if isKeyFrame {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                throw VideoPipelineError.missingFormatDescription
            }
            let configuration = try copyParameterSets(from: formatDescription)
            parameterSets = configuration.parameterSets
            nalUnitHeaderLength = configuration.nalUnitHeaderLength
        }

        return H264EncodedFrame(
            sequence: sequence,
            presentationTimeMicroseconds: presentationTimeMicroseconds,
            durationMicroseconds: durationMicroseconds,
            isKeyFrame: isKeyFrame,
            parameterSets: parameterSets,
            nalUnitHeaderLength: nalUnitHeaderLength,
            payload: payload
        )
    }

    private static func copyParameterSets(
        from formatDescription: CMFormatDescription
    ) throws -> (parameterSets: [Data], nalUnitHeaderLength: UInt8) {
        var parameterSetCount = 0
        var headerLength: Int32 = 0
        var firstPointer: UnsafePointer<UInt8>?
        var firstSize = 0
        let firstStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &firstPointer,
            parameterSetSizeOut: &firstSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard firstStatus == noErr, parameterSetCount >= 2 else {
            throw VideoPipelineError.codecConfigurationExtractionFailed(firstStatus)
        }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(parameterSetCount)
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else {
                throw VideoPipelineError.codecConfigurationExtractionFailed(status)
            }
            parameterSets.append(Data(bytes: pointer, count: size))
        }
        guard (1...4).contains(Int(headerLength)) else {
            throw VideoPipelineError.invalidCodecConfiguration
        }
        return (parameterSets, UInt8(headerLength))
    }
}

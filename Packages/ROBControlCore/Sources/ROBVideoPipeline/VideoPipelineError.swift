import Foundation

public enum VideoPipelineError: Error, LocalizedError, Sendable {
    case unsupportedCodec(String)
    case unsupportedDeliveryMode(String)
    case bitrateExceedsSourceLimit(actual: UInt32, maximum: UInt32)
    case invalidDimensions(width: Int, height: Int)
    case invalidEncoderConfiguration(framesPerSecond: Int, averageBitrate: Int)
    case invalidChannelCapacity(Int)
    case pixelBufferCreationFailed(Int32)
    case pixelBufferPoolExhausted
    case drawingContextCreationFailed
    case compressionSessionCreationFailed(Int32)
    case compressionPropertyFailed(name: String, status: Int32)
    case compressionPreparationFailed(Int32)
    case compressionFailed(Int32)
    case encodedFrameDropped
    case missingEncodedSample
    case missingFormatDescription
    case missingDataBuffer
    case codecConfigurationExtractionFailed(Int32)
    case blockBufferCreationFailed(Int32)
    case blockBufferCopyFailed(Int32)
    case formatDescriptionCreationFailed(Int32)
    case decodedDimensionsMismatch(
        codedWidth: Int32,
        codedHeight: Int32,
        presentationWidth: Double,
        presentationHeight: Double,
        expectedWidth: Int,
        expectedHeight: Int
    )
    case sampleBufferCreationFailed(Int32)
    case invalidCodecConfiguration
    case codecConfigurationGenerationExhausted
    case channelClosed

    public var errorDescription: String? {
        switch self {
        case .unsupportedCodec(let codec):
            "The video pipeline does not support codec \(codec)."
        case .unsupportedDeliveryMode(let mode):
            "The video pipeline does not support delivery mode \(mode)."
        case .bitrateExceedsSourceLimit(let actual, let maximum):
            "Requested video bitrate \(actual) exceeds the source limit of \(maximum)."
        case .invalidDimensions(let width, let height):
            "Invalid video dimensions \(width)×\(height)."
        case .invalidEncoderConfiguration(let framesPerSecond, let averageBitrate):
            "Invalid encoder rate: \(framesPerSecond) fps at \(averageBitrate) bits per second."
        case .invalidChannelCapacity(let capacity):
            "Video channel capacity must be positive; received \(capacity)."
        case .pixelBufferCreationFailed(let status):
            "Pixel-buffer creation failed with status \(status)."
        case .pixelBufferPoolExhausted:
            "The synthetic camera dropped a frame because its pixel-buffer pool is full."
        case .drawingContextCreationFailed:
            "The synthetic camera could not create a drawing context."
        case .compressionSessionCreationFailed(let status):
            "H.264 compression-session creation failed with status \(status)."
        case .compressionPropertyFailed(let name, let status):
            "Setting H.264 property \(name) failed with status \(status)."
        case .compressionPreparationFailed(let status):
            "Preparing the H.264 encoder failed with status \(status)."
        case .compressionFailed(let status):
            "H.264 compression failed with status \(status)."
        case .encodedFrameDropped:
            "VideoToolbox dropped an encoded frame."
        case .missingEncodedSample:
            "The H.264 encoder returned no usable sample."
        case .missingFormatDescription:
            "The encoded sample has no format description."
        case .missingDataBuffer:
            "The encoded sample has no data buffer."
        case .codecConfigurationExtractionFailed(let status):
            "Extracting the H.264 codec configuration failed with status \(status)."
        case .blockBufferCreationFailed(let status):
            "Creating the encoded-video block buffer failed with status \(status)."
        case .blockBufferCopyFailed(let status):
            "Copying encoded-video bytes failed with status \(status)."
        case .formatDescriptionCreationFailed(let status):
            "Creating the H.264 format description failed with status \(status)."
        case .decodedDimensionsMismatch(
            let codedWidth,
            let codedHeight,
            let presentationWidth,
            let presentationHeight,
            let expectedWidth,
            let expectedHeight
        ):
            "H.264 format is coded as \(codedWidth)×\(codedHeight) and presents as "
                + "\(presentationWidth)×\(presentationHeight); negotiated size is "
                + "\(expectedWidth)×\(expectedHeight)."
        case .sampleBufferCreationFailed(let status):
            "Creating the compressed sample buffer failed with status \(status)."
        case .invalidCodecConfiguration:
            "The H.264 codec configuration is incomplete or invalid."
        case .codecConfigurationGenerationExhausted:
            "The H.264 codec-configuration generation counter is exhausted."
        case .channelClosed:
            "The video data channel is closed."
        }
    }
}

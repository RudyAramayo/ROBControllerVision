import CoreMedia
import Foundation

public final class H264SampleBufferFactory {
    private var formatDescription: CMFormatDescription?

    public init() {}

    public func reset() {
        formatDescription = nil
    }

    public func configure(
        sequenceParameterSet: Data,
        pictureParameterSet: Data,
        nalUnitHeaderLength: Int,
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil
    ) throws {
        try configure(
            parameterSets: [sequenceParameterSet, pictureParameterSet],
            nalUnitHeaderLength: nalUnitHeaderLength,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight
        )
    }

    public func configure(
        parameterSets: [Data],
        nalUnitHeaderLength: Int,
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil
    ) throws {
        guard parameterSets.count >= 2,
            parameterSets.allSatisfy({ !$0.isEmpty }),
            (1...4).contains(nalUnitHeaderLength)
        else {
            throw VideoPipelineError.invalidCodecConfiguration
        }

        let allocatedPointers = parameterSets.map { parameterSet -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: parameterSet.count)
            parameterSet.copyBytes(to: pointer, count: parameterSet.count)
            return pointer
        }
        defer {
            for pointer in allocatedPointers {
                pointer.deallocate()
            }
        }
        var pointers = allocatedPointers.map { UnsafePointer<UInt8>($0) }
        var sizes = parameterSets.map(\.count)
        var newDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: Int32(nalUnitHeaderLength),
            formatDescriptionOut: &newDescription
        )
        guard status == noErr, let newDescription else {
            throw VideoPipelineError.formatDescriptionCreationFailed(status)
        }
        if let expectedWidth, let expectedHeight {
            try validateDimensions(
                of: newDescription,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        }
        formatDescription = newDescription
    }

    private func validateDimensions(
        of description: CMVideoFormatDescription,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        let coded = CMVideoFormatDescriptionGetDimensions(description)
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
            description,
            usePixelAspectRatio: false,
            useCleanAperture: true
        )
        let maximumCodedWidth = ((expectedWidth + 15) / 16) * 16
        let maximumCodedHeight = ((expectedHeight + 15) / 16) * 16
        let presentationMatches =
            presentation.width.isFinite
            && presentation.height.isFinite
            && abs(presentation.width - Double(expectedWidth)) < 0.5
            && abs(presentation.height - Double(expectedHeight)) < 0.5
        guard expectedWidth > 0,
            expectedHeight > 0,
            coded.width > 0,
            coded.height > 0,
            Int(coded.width) <= maximumCodedWidth,
            Int(coded.height) <= maximumCodedHeight,
            presentationMatches
        else {
            throw VideoPipelineError.decodedDimensionsMismatch(
                codedWidth: coded.width,
                codedHeight: coded.height,
                presentationWidth: presentation.width,
                presentationHeight: presentation.height,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        }
    }

    public func makeSampleBuffer(
        payload: Data,
        presentationTime: CMTime,
        duration: CMTime,
        isKeyFrame: Bool,
        displayImmediately: Bool = true
    ) throws -> CMSampleBuffer {
        guard let formatDescription else {
            throw VideoPipelineError.invalidCodecConfiguration
        }
        guard !payload.isEmpty else {
            throw VideoPipelineError.missingDataBuffer
        }

        var blockBuffer: CMBlockBuffer?
        let creationStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard creationStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw VideoPipelineError.blockBufferCreationFailed(creationStatus)
        }

        let copyStatus = payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw VideoPipelineError.blockBufferCopyFailed(copyStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw VideoPipelineError.sampleBufferCreationFailed(sampleStatus)
        }

        setSampleAttachment(
            kCMSampleAttachmentKey_NotSync,
            value: isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue,
            on: sampleBuffer
        )
        if displayImmediately {
            setSampleAttachment(
                kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                on: sampleBuffer
            )
        }
        return sampleBuffer
    }

    private func setSampleAttachment(
        _ key: CFString,
        value: CFBoolean,
        on sampleBuffer: CMSampleBuffer
    ) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: true
            ),
            CFArrayGetCount(attachments) > 0
        else { return }

        let rawDictionary = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(rawDictionary, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }
}

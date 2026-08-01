import Foundation
import Testing

@testable import ROBControlCore

@Suite("Encoded video data protocol")
struct EncodedVideoProtocolTests {
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let otherSessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let streamID = VideoSubscriptionID(
        rawValue: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    )

    @Test("JPEG access units round-trip through the explicit wire schema")
    func jpegRoundTrip() throws {
        let message = VideoDataMessage.accessUnit(try jpegAccessUnit())
        let codec = VideoDataMessageCodec()

        let data = try codec.encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["protocolVersion"] as? Int == 1)
        #expect(object["type"] as? String == "accessUnit")
        #expect(object["codecConfiguration"] == nil)
        #expect(try codec.decode(data) == message)
    }

    @Test("Unsupported versions and unknown envelope fields fail closed")
    func strictEnvelopeDecoding() throws {
        let codec = VideoDataMessageCodec()
        let encoded = try codec.encode(.accessUnit(jpegAccessUnit()))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object["protocolVersion"] = 99
        let unsupportedVersion = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try codec.decode(unsupportedVersion)
            Issue.record("Expected an unsupported protocol version to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .unsupportedProtocolVersion(99))
        }

        object["protocolVersion"] = 1
        object["untrusted"] = true
        let unknownField = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try codec.decode(unknownField)
            Issue.record("Expected an unknown field to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .unexpectedFields(["untrusted"]))
        }
    }

    @Test("Receiver disposition distinguishes stale datagrams from malformed media")
    func receiverValidationDisposition() {
        #expect(
            VideoDataValidationError.sequenceNotIncreasing(previous: 4, received: 4)
                .isDiscardableByReceiver
        )
        #expect(
            VideoDataValidationError.sessionMismatch(
                expected: sessionID,
                received: otherSessionID
            ).isDiscardableByReceiver
        )
        #expect(!VideoDataValidationError.invalidLengthPrefixedAccessUnit.isDiscardableByReceiver)
        #expect(VideoDataValidationError.invalidLengthPrefixedAccessUnit.shouldRequestKeyFrame)
    }

    @Test("Tagged envelopes reject contradictory payloads")
    func taggedEnvelopeRejectsContradictoryPayloads() throws {
        let codec = VideoDataMessageCodec()
        let encoded = try codec.encode(.accessUnit(jpegAccessUnit()))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["codecConfiguration"] = object["accessUnit"]
        let contradictory = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try codec.decode(contradictory)
            Issue.record("Expected contradictory tagged payloads to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .invalidTaggedMessagePayload)
        }
    }

    @Test("Serialized and decoded payloads obey channel limits")
    func boundedPayloads() throws {
        let limits = try VideoDataChannelLimits(
            maximumAccessUnitBytes: 4,
            maximumCodecConfigurationBytes: 64,
            maximumSerializedMessageBytes: 512
        )
        let codec = VideoDataMessageCodec(limits: limits)
        let tooLargeAccessUnit = try jpegAccessUnit(payload: Data([0xFF, 0xD8, 0x00, 0x00, 0xFF, 0xD9]))

        do {
            _ = try codec.encode(.accessUnit(tooLargeAccessUnit))
            Issue.record("Expected the local access-unit limit to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .accessUnitTooLarge(actualBytes: 6, maximumBytes: 4))
        }

        let oversizedEnvelope = Data(
            repeating: 0,
            count: VideoDataChannelLimits.hardMaximumSerializedMessageBytes + 1
        )
        do {
            _ = try VideoDataMessageCodec().decode(oversizedEnvelope)
            Issue.record("Expected serialized size preflight to fail")
        } catch let error as VideoDataValidationError {
            #expect(
                error
                    == .serializedMessageTooLarge(
                        actualBytes: oversizedEnvelope.count,
                        maximumBytes: VideoDataChannelLimits.hardMaximumSerializedMessageBytes
                    )
            )
        }
    }

    @Test("JPEG metadata and markers are validated")
    func jpegValidation() throws {
        do {
            _ = try jpegAccessUnit(isKeyFrame: false)
            Issue.record("Expected a non-key JPEG to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .invalidJPEGMetadata)
        }

        do {
            _ = try jpegAccessUnit(payload: Data([0x00, 0xD8, 0xFF, 0xD9]))
            Issue.record("Expected invalid JPEG markers to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .invalidJPEGPayload)
        }
    }

    @Test("Stream validator rejects stale sessions and cross-stream frames")
    func identityValidation() throws {
        var validator = VideoStreamValidator(sessionID: sessionID, stream: stream(codec: .jpeg))
        let staleFrame = try jpegAccessUnit(sessionID: otherSessionID)

        do {
            _ = try validator.accept(.accessUnit(staleFrame))
            Issue.record("Expected stale-session data to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .sessionMismatch(expected: sessionID, received: otherSessionID))
        }

        let otherStreamID = VideoSubscriptionID()
        let crossStreamFrame = try jpegAccessUnit(streamID: otherStreamID)
        do {
            _ = try validator.accept(.accessUnit(crossStreamFrame))
            Issue.record("Expected cross-stream data to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .streamMismatch(expected: streamID, received: otherStreamID))
        }
    }

    @Test("Sequence and presentation timestamps increase monotonically")
    func orderingValidation() throws {
        var validator = VideoStreamValidator(sessionID: sessionID, stream: stream(codec: .jpeg))
        _ = try validator.accept(.accessUnit(jpegAccessUnit(sequence: 5, presentationTimestamp: 100)))

        do {
            _ = try validator.accept(.accessUnit(jpegAccessUnit(sequence: 5, presentationTimestamp: 101)))
            Issue.record("Expected a duplicate sequence to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .sequenceNotIncreasing(previous: 5, received: 5))
        }

        do {
            _ = try validator.accept(.accessUnit(jpegAccessUnit(sequence: 6, presentationTimestamp: 100)))
            Issue.record("Expected a duplicate timestamp to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .presentationTimestampNotIncreasing(previous: 100, received: 100))
        }

        let next = try jpegAccessUnit(sequence: 8, presentationTimestamp: 102)
        #expect(try validator.accept(.accessUnit(next)) == next)
    }

    @Test("Timescale is stable and frame duration is bounded")
    func timingValidation() throws {
        var validator = VideoStreamValidator(sessionID: sessionID, stream: stream(codec: .jpeg))
        _ = try validator.accept(.accessUnit(jpegAccessUnit(sequence: 0, presentationTimestamp: 0)))

        let changedTimescale = try jpegAccessUnit(
            sequence: 1,
            presentationTimestamp: 1,
            timescale: 60
        )
        do {
            _ = try validator.accept(.accessUnit(changedTimescale))
            Issue.record("Expected a mid-stream timescale change to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .timescaleMismatch(expected: 30, received: 60))
        }

        do {
            _ = try jpegAccessUnit(duration: 301, timescale: 30)
            Issue.record("Expected a frame duration over ten seconds to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .durationExceedsMaximum(duration: 301, timescale: 30))
        }
    }

    @Test("H264 requires configuration and an initial random-access frame")
    func h264DecoderReadiness() throws {
        var validator = VideoStreamValidator(sessionID: sessionID, stream: stream(codec: .h264))
        let configuration = try h264Configuration(generation: 1)
        #expect(try validator.accept(.codecConfiguration(configuration)) == nil)

        let delta = try h264AccessUnit(
            sequence: 0,
            presentationTimestamp: 0,
            isKeyFrame: false,
            nalHeader: 0x41
        )
        do {
            _ = try validator.accept(.accessUnit(delta))
            Issue.record("Expected a delta frame before the key frame to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .keyFrameRequired)
        }

        let keyFrame = try h264AccessUnit(
            sequence: 0,
            presentationTimestamp: 0,
            isKeyFrame: true,
            nalHeader: 0x65
        )
        #expect(try validator.accept(.accessUnit(keyFrame)) == keyFrame)

        let nextDelta = try h264AccessUnit(
            sequence: 1,
            presentationTimestamp: 1,
            isKeyFrame: false,
            nalHeader: 0x41
        )
        #expect(try validator.accept(.accessUnit(nextDelta)) == nextDelta)
    }

    @Test("H264 rejects missing configuration, malformed framing, and false key-frame claims")
    func h264FramingValidation() throws {
        var validator = VideoStreamValidator(sessionID: sessionID, stream: stream(codec: .h264))
        let keyFrame = try h264AccessUnit(
            sequence: 0,
            presentationTimestamp: 0,
            isKeyFrame: true,
            nalHeader: 0x65
        )

        do {
            _ = try validator.accept(.accessUnit(keyFrame))
            Issue.record("Expected a missing configuration to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .codecConfigurationRequired)
        }

        _ = try validator.accept(.codecConfiguration(h264Configuration(generation: 1)))
        let malformedFraming = try h264AccessUnit(
            sequence: 0,
            presentationTimestamp: 0,
            isKeyFrame: true,
            payload: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x00])
        )
        do {
            _ = try validator.accept(.accessUnit(malformedFraming))
            Issue.record("Expected malformed length-prefixed framing to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .invalidLengthPrefixedAccessUnit)
        }

        let falseKeyFrame = try h264AccessUnit(
            sequence: 0,
            presentationTimestamp: 0,
            isKeyFrame: true,
            nalHeader: 0x41
        )
        do {
            _ = try validator.accept(.accessUnit(falseKeyFrame))
            Issue.record("Expected a key-frame flag without an IDR NAL to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .keyFrameFlagDoesNotMatchPayload)
        }
    }

    @Test("New codec generations require a matching frame generation and key frame")
    func codecGenerationValidation() throws {
        var validator = VideoStreamValidator(sessionID: sessionID, stream: stream(codec: .h264))
        _ = try validator.accept(.codecConfiguration(h264Configuration(generation: 1)))
        _ = try validator.accept(
            .accessUnit(
                h264AccessUnit(
                    sequence: 0,
                    presentationTimestamp: 0,
                    isKeyFrame: true,
                    nalHeader: 0x65
                )
            )
        )
        _ = try validator.accept(.codecConfiguration(h264Configuration(generation: 2)))

        let staleGeneration = try h264AccessUnit(
            sequence: 1,
            presentationTimestamp: 1,
            isKeyFrame: true,
            configurationGeneration: 1,
            nalHeader: 0x65
        )
        do {
            _ = try validator.accept(.accessUnit(staleGeneration))
            Issue.record("Expected a stale frame generation to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .codecConfigurationGenerationMismatch(expected: 2, received: 1))
        }

        #expect(try validator.accept(.codecConfiguration(h264Configuration(generation: 2))) == nil)

        let conflictingConfiguration = try h264Configuration(
            generation: 2,
            spsBytes: Data([0x67, 0x43])
        )
        do {
            _ = try validator.accept(.codecConfiguration(conflictingConfiguration))
            Issue.record("Expected conflicting contents for a repeated generation to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .codecConfigurationGenerationConflict(2))
        }
    }

    @Test("A sequence gap invalidates predictive frames until a new key frame")
    func sequenceGapRecovery() throws {
        var validator = VideoStreamValidator(sessionID: sessionID, stream: stream(codec: .h264))
        _ = try validator.accept(.codecConfiguration(h264Configuration(generation: 1)))
        _ = try validator.accept(
            .accessUnit(
                h264AccessUnit(
                    sequence: 10,
                    presentationTimestamp: 10,
                    isKeyFrame: true,
                    nalHeader: 0x65
                )
            )
        )

        let deltaAfterGap = try h264AccessUnit(
            sequence: 12,
            presentationTimestamp: 12,
            isKeyFrame: false,
            nalHeader: 0x41
        )
        do {
            _ = try validator.accept(.accessUnit(deltaAfterGap))
            Issue.record("Expected a predictive frame after a sequence gap to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .keyFrameRequired)
            #expect(error.shouldRequestKeyFrame)
        }

        let recoveryFrame = try h264AccessUnit(
            sequence: 12,
            presentationTimestamp: 12,
            isKeyFrame: true,
            nalHeader: 0x65
        )
        #expect(try validator.accept(.accessUnit(recoveryFrame)) == recoveryFrame)
    }

    @Test("Codec parameter sets are type checked")
    func parameterSetValidation() throws {
        let sps = try VideoCodecParameterSet(kind: .sps, bytes: Data([0x67, 0x42]))

        do {
            _ = try VideoCodecConfiguration(
                sessionID: sessionID,
                streamID: streamID,
                codec: .h264,
                generation: 1,
                parameterSets: [sps],
                nalLengthFieldBytes: 4
            )
            Issue.record("Expected a missing PPS to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .missingRequiredCodecParameterSets(codec: .h264))
        }

        let incorrectlyTaggedPPS = try VideoCodecParameterSet(kind: .pps, bytes: Data([0x67]))
        do {
            _ = try VideoCodecConfiguration(
                sessionID: sessionID,
                streamID: streamID,
                codec: .h264,
                generation: 1,
                parameterSets: [sps, incorrectlyTaggedPPS],
                nalLengthFieldBytes: 4
            )
            Issue.record("Expected a mismatched NAL header to fail")
        } catch let error as VideoDataValidationError {
            #expect(error == .invalidCodecParameterSet(codec: .h264, kind: .pps))
        }
    }

    private func stream(codec: VideoCodec) -> VideoStreamDescriptor {
        VideoStreamDescriptor(
            id: streamID,
            cameraID: CameraID(rawValue: "front"),
            codec: codec,
            width: 640,
            height: 360,
            framesPerSecond: 30,
            bitrate: 1_000_000,
            delivery: codec == .jpeg ? .jpegFrames : .reliableStream
        )
    }

    private func jpegAccessUnit(
        sessionID: UUID? = nil,
        streamID: VideoSubscriptionID? = nil,
        sequence: UInt64 = 0,
        presentationTimestamp: Int64 = 0,
        duration: Int64 = 1,
        timescale: Int32 = 30,
        isKeyFrame: Bool = true,
        payload: Data = Data([0xFF, 0xD8, 0xFF, 0xD9])
    ) throws -> EncodedVideoAccessUnit {
        try EncodedVideoAccessUnit(
            sessionID: sessionID ?? self.sessionID,
            streamID: streamID ?? self.streamID,
            codec: .jpeg,
            sequence: sequence,
            captureTimestampUnixMilliseconds: 1_000,
            presentationTimestamp: presentationTimestamp,
            duration: duration,
            timescale: timescale,
            isKeyFrame: isKeyFrame,
            codecConfigurationGeneration: nil,
            payload: payload
        )
    }

    private func h264Configuration(
        generation: UInt32,
        spsBytes: Data = Data([0x67, 0x42])
    ) throws -> VideoCodecConfiguration {
        try VideoCodecConfiguration(
            sessionID: sessionID,
            streamID: streamID,
            codec: .h264,
            generation: generation,
            parameterSets: [
                try VideoCodecParameterSet(kind: .sps, bytes: spsBytes),
                try VideoCodecParameterSet(kind: .pps, bytes: Data([0x68, 0xCE])),
            ],
            nalLengthFieldBytes: 4
        )
    }

    private func h264AccessUnit(
        sequence: UInt64,
        presentationTimestamp: Int64,
        isKeyFrame: Bool,
        configurationGeneration: UInt32 = 1,
        nalHeader: UInt8 = 0x65,
        payload: Data? = nil
    ) throws -> EncodedVideoAccessUnit {
        try EncodedVideoAccessUnit(
            sessionID: sessionID,
            streamID: streamID,
            codec: .h264,
            sequence: sequence,
            captureTimestampUnixMilliseconds: 1_000 + presentationTimestamp,
            presentationTimestamp: presentationTimestamp,
            duration: 1,
            timescale: 30,
            isKeyFrame: isKeyFrame,
            codecConfigurationGeneration: configurationGeneration,
            payload: payload ?? Data([0x00, 0x00, 0x00, 0x02, nalHeader, 0x00])
        )
    }
}

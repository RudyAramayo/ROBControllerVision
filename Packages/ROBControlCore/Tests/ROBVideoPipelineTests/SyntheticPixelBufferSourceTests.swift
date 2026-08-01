import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import ROBVideoPipeline

@Suite("Synthetic pixel-buffer source")
struct SyntheticPixelBufferSourceTests {
    @Test("Invalid frame dimensions are rejected")
    func invalidDimensions() {
        #expect(throws: VideoPipelineError.self) {
            _ = try SyntheticPixelBufferSource(width: 0, height: 360)
        }
    }

    @Test("A camera frame has the requested dimensions")
    func frameDimensions() throws {
        let source = try SyntheticPixelBufferSource(width: 320, height: 180)
        let frame = try source.makeFrame(sequence: 1)

        #expect(CVPixelBufferGetWidth(frame) == 320)
        #expect(CVPixelBufferGetHeight(frame) == 180)
    }

    @Test("Synthetic frames encode and reconstruct as compressed H.264 samples")
    func h264RoundTrip() async throws {
        let output = AsyncStream<Result<H264EncodedFrame, VideoPipelineError>>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let encoder = try H264VideoEncoder(
            width: 320,
            height: 180,
            framesPerSecond: 15,
            averageBitrate: 500_000
        ) { result in
            output.continuation.yield(result)
        }
        let source = try SyntheticPixelBufferSource(width: 320, height: 180)
        try encoder.encode(
            source.makeFrame(sequence: 1),
            sequence: 1,
            presentationTimeMicroseconds: 0,
            durationMicroseconds: 66_667,
            forceKeyFrame: true
        )

        let encodedResult = await firstValue(in: output.stream, timeout: .seconds(2))
        let encoded = try #require(try encodedResult?.get())
        #expect(encoded.isKeyFrame)
        #expect(encoded.payload.count > 0)
        let parameterSets = try #require(encoded.parameterSets)
        #expect(parameterSets.count >= 2)

        let factory = H264SampleBufferFactory()
        #expect(throws: VideoPipelineError.self) {
            try factory.configure(
                sequenceParameterSet: parameterSets[0],
                pictureParameterSet: parameterSets[1],
                nalUnitHeaderLength: Int(encoded.nalUnitHeaderLength),
                expectedWidth: 640,
                expectedHeight: 360
            )
        }
        try factory.configure(
            sequenceParameterSet: parameterSets[0],
            pictureParameterSet: parameterSets[1],
            nalUnitHeaderLength: Int(encoded.nalUnitHeaderLength),
            expectedWidth: 320,
            expectedHeight: 180
        )
        let sample = try factory.makeSampleBuffer(
            payload: encoded.payload,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 15),
            isKeyFrame: encoded.isKeyFrame
        )
        #expect(CMSampleBufferDataIsReady(sample))
        encoder.finish()
        output.continuation.finish()
    }

    private func firstValue<Element: Sendable>(
        in stream: AsyncStream<Element>,
        timeout: Duration
    ) async -> Element? {
        await withTaskGroup(of: Element?.self) { group in
            group.addTask {
                for await value in stream {
                    return value
                }
                return nil
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: timeout)
                return nil
            }

            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }
}

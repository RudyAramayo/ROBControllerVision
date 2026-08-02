import Foundation
import ROBControlCore
import Testing

@testable import ROBCerebroTransport

@Suite("Cerebro video wire compatibility")
struct ROBVideoWireCompatibilityTests {
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let streamID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    @Test("Subscription JSON uses Cerebro's plain UUID schema")
    func subscriptionJSON() throws {
        let request = VideoSubscriptionRequest(
            id: VideoSubscriptionID(rawValue: streamID),
            cameraID: CameraID(rawValue: "front"),
            preferredCodecs: [.h264],
            constraints: VideoConstraints(
                maximumWidth: 960,
                maximumHeight: 540,
                maximumFramesPerSecond: 20,
                maximumBitrate: 1_500_000
            ),
            delivery: .reliableStream
        )
        let wire = try ROBVideoWireSubscriptionRequest(sessionID: sessionID, request: request)
        let data = try ROBVideoJSONCodec.encode(wire)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["protocolVersion"] as? Int == 1)
        #expect(object["sessionID"] as? String == sessionID.uuidString)
        #expect(object["id"] as? String == streamID.uuidString)
        #expect(object["cameraID"] as? String == "front")
        #expect(object["delivery"] as? String == "reliableStream")
    }

    @Test("Cerebro RBVD configuration and IDR golden vectors decode")
    func mediaGoldenVectors() throws {
        let stream = VideoStreamDescriptor(
            id: VideoSubscriptionID(rawValue: streamID),
            cameraID: CameraID(rawValue: "front"),
            codec: .h264,
            width: 960,
            height: 540,
            framesPerSecond: 20,
            bitrate: 1_500_000,
            delivery: .reliableStream
        )
        var decoder = try ROBVideoBinaryDecoder(sessionID: sessionID, stream: stream)

        let configuration = try decoder.decode(Data(hex: Self.configurationHex))
        guard case .codecConfiguration(let decodedConfiguration) = configuration else {
            Issue.record("Expected an H.264 configuration message")
            return
        }
        #expect(decodedConfiguration.generation == 1)
        #expect(decodedConfiguration.nalLengthFieldBytes == 4)
        #expect(decodedConfiguration.parameterSets.map(\.kind) == [.sps, .pps])

        let accessUnit = try decoder.decode(Data(hex: Self.accessUnitHex))
        guard case .accessUnit(let decodedAccessUnit) = accessUnit else {
            Issue.record("Expected an H.264 access unit")
            return
        }
        #expect(decodedAccessUnit.sequence == 7)
        #expect(decodedAccessUnit.isKeyFrame)
        #expect(decodedAccessUnit.codecConfigurationGeneration == 1)
        #expect(decodedAccessUnit.payload == Data([0, 0, 0, 2, 0x65, 0x88]))
    }

    @Test("RBVD reserved bits fail closed")
    func reservedBitsAreRejected() throws {
        var data = try Data(hex: Self.accessUnitHex)
        data[7] |= 0x80
        let stream = VideoStreamDescriptor(
            id: VideoSubscriptionID(rawValue: streamID),
            cameraID: CameraID(rawValue: "front"),
            codec: .h264,
            width: 960,
            height: 540,
            framesPerSecond: 20,
            bitrate: 1_500_000,
            delivery: .reliableStream
        )
        var decoder = try ROBVideoBinaryDecoder(sessionID: sessionID, stream: stream)
        #expect(throws: ROBCerebroTransportError.invalidWireMessage) {
            _ = try decoder.decode(data)
        }
    }

    private static let configurationHex =
        "5242564401010200005c000000000018"
        + "11111111222233334444555555555555"
        + "99999999888877776666555555555555"
        + "00000000000000000000000000000000"
        + "00000000000000000000000000000000"
        + "000000000000000104020000"
        + "02000000000000046742001f"
        + "030000000000000468ce06e2"

    private static let accessUnitHex =
        "5242564401020201005c000000000006"
        + "11111111222233334444555555555555"
        + "99999999888877776666555555555555"
        + "0000000000000007"
        + "0000019fbb315464"
        + "00000000000493e0"
        + "000000000000c350"
        + "000f42400000000104000000"
        + "000000026588"
}

extension Data {
    fileprivate init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else {
            throw ROBCerebroTransportError.invalidWireMessage
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw ROBCerebroTransportError.invalidWireMessage
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

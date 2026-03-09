import XCTest
import MessagePacker
@testable import TidyFlow

final class TypedMessagePackEnvelopeTests: XCTestCase {
    private struct TestTypedRequest: TypedWSRequest {
        let count: Int
        let enabled: Bool
        let items: [String]
        let metadata: [String: String]

        var action: String { "test_typed_request" }
    }

    private struct DecodedEnvelope: Decodable {
        let requestID: String
        let domain: String
        let action: String
        let payload: [String: AnyCodable]
        let clientTs: UInt64

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case domain
            case action
            case payload
            case clientTs = "client_ts"
        }
    }

    func testEncodeTypedEnvelopeUsesDirectMessagePackPayload() throws {
        let client = WSClient()
        let request = TestTypedRequest(
            count: 0,
            enabled: false,
            items: [],
            metadata: [:]
        )

        let data = try client.encodeTypedEnvelope(request, requestId: "req-typed-1")
        let envelope = try MessagePackDecoder().decode(DecodedEnvelope.self, from: data)

        XCTAssertEqual(envelope.requestID, "req-typed-1")
        XCTAssertEqual(envelope.domain, "misc")
        XCTAssertEqual(envelope.action, "test_typed_request")
        XCTAssertGreaterThan(envelope.clientTs, 0)
        XCTAssertNil(envelope.payload["type"], "typed payload 不应再携带 type 字段")

        guard case .int(let count)? = envelope.payload["count"] else {
            return XCTFail("count 应保持为整型")
        }
        XCTAssertEqual(count, 0)

        guard case .bool(let enabled)? = envelope.payload["enabled"] else {
            return XCTFail("enabled 应保持为布尔值")
        }
        XCTAssertFalse(enabled)

        guard case .array(let items)? = envelope.payload["items"] else {
            return XCTFail("items 应保持为数组")
        }
        XCTAssertTrue(items.isEmpty)

        guard case .dictionary(let metadata)? = envelope.payload["metadata"] else {
            return XCTFail("metadata 应保持为字典")
        }
        XCTAssertTrue(metadata.isEmpty)
    }
}

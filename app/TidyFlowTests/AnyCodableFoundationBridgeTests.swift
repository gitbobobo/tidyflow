import XCTest
@testable import TidyFlow
@testable import TidyFlowShared

final class AnyCodableFoundationBridgeTests: XCTestCase {
    func testNSNumberZeroStaysInteger() {
        let value = AnyCodable.from(NSNumber(value: 0))

        guard case .int(let intValue) = value else {
            return XCTFail("NSNumber(0) 应编码为整型")
        }
        XCTAssertEqual(intValue, 0)
    }

    func testNSNumberFalseStaysBool() {
        let value = AnyCodable.from(NSNumber(value: false))

        guard case .bool(let boolValue) = value else {
            return XCTFail("NSNumber(false) 应编码为布尔值")
        }
        XCTAssertFalse(boolValue)
    }

    func testJSONSerializationEmptyArrayStaysArray() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data("{\"items\":[]}".utf8)) as? [String: Any]
        )
        let value = AnyCodable.from(try XCTUnwrap(object["items"]))

        guard case .array(let arrayValue) = value else {
            return XCTFail("空数组不应退化成字符串")
        }
        XCTAssertTrue(arrayValue.isEmpty)
    }

    func testJSONSerializationEmptyDictionaryStaysDictionary() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data("{\"payload\":{}}".utf8)) as? [String: Any]
        )
        let value = AnyCodable.from(try XCTUnwrap(object["payload"]))

        guard case .dictionary(let dictionaryValue) = value else {
            return XCTFail("空字典不应退化成字符串")
        }
        XCTAssertTrue(dictionaryValue.isEmpty)
    }
}

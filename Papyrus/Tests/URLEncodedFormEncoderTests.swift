import XCTest
@testable import Papyrus

final class URLEncodedFormEncoderTests: XCTestCase {
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { self.stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Mirrors ReerCodable's `encoder.set(_:forKey:)`: every property opens its own keyed container.
    private struct PerPropertyContainers: Encodable {
        let username: String
        let password: String

        func encode(to encoder: any Encoder) throws {
            var first = encoder.container(keyedBy: AnyKey.self)
            try first.encode(username, forKey: AnyKey("username"))
            var second = encoder.container(keyedBy: AnyKey.self)
            try second.encode(password, forKey: AnyKey("password"))
        }
    }

    private struct Wrapper: Encodable {
        let grantType: String
        let credentials: PerPropertyContainers

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case credentials
        }
    }

    private struct NestedContainerThenRepeated: Encodable {
        func encode(to encoder: any Encoder) throws {
            var outer = encoder.container(keyedBy: AnyKey.self)
            var nested = outer.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("inner"))
            try nested.encode("1", forKey: AnyKey("a"))
            try outer.encode(PerPropertyContainers(username: "u", password: "p"), forKey: AnyKey("creds"))
            var again = encoder.container(keyedBy: AnyKey.self)
            try again.encode("2", forKey: AnyKey("b"))
        }
    }

    private func pairs(_ string: String) -> Set<String> {
        Set(string.split(separator: "&").map(String.init))
    }

    func testRepeatedKeyedContainerAtTopLevelKeepsEveryKey() throws {
        let output: String = try URLEncodedFormEncoder().encode(PerPropertyContainers(username: "123", password: "secret"))
        XCTAssertEqual(pairs(output), ["username=123", "password=secret"])
    }

    func testRepeatedKeyedContainerAtNestedLevelKeepsEveryKey() throws {
        let value = Wrapper(grantType: "password", credentials: .init(username: "123", password: "secret"))
        let output: String = try URLEncodedFormEncoder().encode(value)
        XCTAssertEqual(pairs(output), [
            "grant_type=password",
            "credentials[username]=123",
            "credentials[password]=secret"
        ])
    }

    func testRepeatedKeyedContainerAfterNestedContainersKeepsEveryKey() throws {
        let output: String = try URLEncodedFormEncoder().encode(NestedContainerThenRepeated())
        XCTAssertEqual(pairs(output), [
            "inner[a]=1",
            "creds[username]=u",
            "creds[password]=p",
            "b=2"
        ])
    }

    func testSynthesizedEncodableIsUnchanged() throws {
        struct Plain: Encodable {
            let a: String
            let b: [Int]
            let c: [String: String]
        }
        let output: String = try URLEncodedFormEncoder().encode(Plain(a: "x", b: [1, 2], c: ["k": "v"]))
        XCTAssertEqual(pairs(output), ["a=x", "b[]=1", "b[]=2", "c[k]=v"])
    }
}

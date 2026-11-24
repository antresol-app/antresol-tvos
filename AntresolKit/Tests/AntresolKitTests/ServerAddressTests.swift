import Foundation
import XCTest
@testable import AntresolKit

/// Which addresses are tried, in which order, and which would send the password in the clear.
final class ServerAddressTests: XCTestCase {
    private func candidates(_ input: String) -> [String] {
        ServerAddress.candidates(for: input).map(\.absoluteString)
    }

    func testHomeNetworkAddressesAreTriedOverHttpOnly() {
        XCTAssertEqual(candidates("192.168.1.10"), ["http://192.168.1.10:8420"])
        XCTAssertEqual(candidates("10.0.0.2:9000"), ["http://10.0.0.2:9000"])
        XCTAssertEqual(candidates("172.20.0.1"), ["http://172.20.0.1:8420"])
        XCTAssertEqual(candidates("169.254.3.4"), ["http://169.254.3.4:8420"])
        XCTAssertEqual(candidates("100.101.102.103"), ["http://100.101.102.103:8420"])
        XCTAssertEqual(candidates("nas"), ["http://nas:8420"])
        XCTAssertEqual(candidates("nas.local:9000"), ["http://nas.local:9000"])
        XCTAssertEqual(candidates("media.lan"), ["http://media.lan:8420"])
        XCTAssertEqual(candidates("[fd00::5]"), ["http://[fd00::5]:8420"])
    }

    func testPublicHostWithoutSchemeTriesHttpsFirst() {
        XCTAssertEqual(candidates("media.example.com"), ["https://media.example.com", "http://media.example.com:8420"])
        XCTAssertEqual(candidates("media.example.com/api/"), ["https://media.example.com", "http://media.example.com:8420"])
        XCTAssertEqual(candidates("media.example.com:9000"), ["https://media.example.com:9000", "http://media.example.com:9000"])
        XCTAssertEqual(candidates("172.32.0.1"), ["https://172.32.0.1", "http://172.32.0.1:8420"])
        XCTAssertEqual(candidates("100.128.0.1"), ["https://100.128.0.1", "http://100.128.0.1:8420"])
    }

    func testATypedSchemeIsKept() {
        XCTAssertEqual(candidates("http://media.example.com"), ["http://media.example.com"])
        XCTAssertEqual(candidates("https://media.example.com/"), ["https://media.example.com"])
        XCTAssertEqual(candidates("http://192.168.1.10:8420"), ["http://192.168.1.10:8420"])
    }

    func testNotAnAddressHasNoCandidates() {
        XCTAssertEqual(candidates(""), [])
        XCTAssertEqual(candidates("two words"), [])
        XCTAssertEqual(candidates("ftp://x"), [])
    }

    func testOnlyPlainHttpAwayFromHomeIsUnencryptedRemote() throws {
        func remote(_ text: String) throws -> Bool {
            ServerAddress.isUnencryptedRemote(try XCTUnwrap(URL(string: text)))
        }
        XCTAssertTrue(try remote("http://media.example.com"))
        XCTAssertTrue(try remote("http://8.8.8.8:8420"))
        XCTAssertTrue(try remote("http://[2001:db8::1]:8420"))
        XCTAssertFalse(try remote("https://media.example.com"))
        XCTAssertFalse(try remote("http://192.168.1.10:8420"))
        XCTAssertFalse(try remote("http://localhost:8420"))
        XCTAssertFalse(try remote("http://127.0.0.1:8420"))
        XCTAssertFalse(try remote("http://nas.local:8420"))
        XCTAssertFalse(try remote("http://[fe80::1]:8420"))
    }
}

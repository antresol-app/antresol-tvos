import Foundation
import XCTest
@testable import AntresolKit

final class DiscoveryTests: XCTestCase {
    let id = "0123456789abcdef0123456789abcdef"

    func testFullAdvertisement() throws {
        let ad = try XCTUnwrap(ServerDiscovery.advertisement(fromTXT: [
            "txtvers": "1", "id": id, "name": "Дом на даче", "version": "1.4.0", "scheme": "http", "port": "8420", "path": "/",
        ]))
        XCTAssertEqual(ad.id, id)
        XCTAssertEqual(ad.name, "Дом на даче")
        XCTAssertEqual(ad.version, "1.4.0")
        XCTAssertEqual(ad.scheme, "http")
        XCTAssertEqual(ad.port, 8420)
        XCTAssertEqual(ad.path, "", "the root path adds nothing to the URL")
        XCTAssertEqual(ad.txtVersion, 1)
        XCTAssertEqual(ServerDiscovery.baseURL(host: "192.168.1.10", port: 8420, advertisement: ad)?.absoluteString, "http://192.168.1.10:8420")
    }

    func testMissingOrBadIDIsIgnored() {
        XCTAssertNil(ServerDiscovery.advertisement(fromTXT: ["name": "Antresol"]))
        XCTAssertNil(ServerDiscovery.advertisement(fromTXT: ["id": "0123"]))
        XCTAssertNil(ServerDiscovery.advertisement(fromTXT: ["id": String(repeating: "g", count: 32)]))
        XCTAssertNil(ServerDiscovery.advertisement(fromTXT: ["id": id, "scheme": "ftp"]))
    }

    func testDefaultsAndTolerance() throws {
        // upper-case keys and id, a newer txtvers with the keys present, no name or port
        let ad = try XCTUnwrap(ServerDiscovery.advertisement(fromTXT: ["ID": id.uppercased(), "TxtVers": "2", "path": "media/"]))
        XCTAssertEqual(ad.id, id)
        XCTAssertEqual(ad.name, "Antresol")
        XCTAssertEqual(ad.txtVersion, 2)
        XCTAssertNil(ad.port)
        XCTAssertEqual(ad.path, "/media")
        // the SRV port is used when TXT has none
        XCTAssertEqual(ServerDiscovery.baseURL(host: "10.0.0.5", port: 9000, advertisement: ad)?.absoluteString, "http://10.0.0.5:9000/media")
        XCTAssertNil(ServerDiscovery.advertisement(fromTXT: ["id": id, "port": "99999"])?.port)
    }

    func testBaseURLHosts() {
        let ad = ServerDiscovery.Advertisement(id: id, name: "A", port: 8420)
        XCTAssertEqual(ServerDiscovery.baseURL(host: "fe80::1%en0", port: 8420, advertisement: ad)?.absoluteString, "http://[fe80::1]:8420")
        XCTAssertNil(ServerDiscovery.baseURL(host: "", port: 8420, advertisement: ad))
        XCTAssertNil(ServerDiscovery.baseURL(host: "1.2.3.4", port: 0, advertisement: ServerDiscovery.Advertisement(id: id, name: "A")))
    }

    func testMergedDeduplicatesByIDAndSortsByName() {
        let other = "fedcba9876543210fedcba9876543210"
        let list = DiscoveredServer.merged([
            DiscoveredServer(id: id, name: "Zeta", version: "1", baseURL: URL(string: "http://10.0.0.2:8420")!),
            DiscoveredServer(id: other, name: "alpha", version: "1", baseURL: URL(string: "http://10.0.0.3:8420")!),
            DiscoveredServer(id: id, name: "Zeta", version: "2", baseURL: URL(string: "http://10.0.0.9:8420")!),
        ])
        XCTAssertEqual(list.map(\.id), [other, id])
        XCTAssertEqual(list.last?.address, "10.0.0.9:8420", "the latest sighting of a server wins")
        XCTAssertEqual(list.last?.version, "2")
    }
}

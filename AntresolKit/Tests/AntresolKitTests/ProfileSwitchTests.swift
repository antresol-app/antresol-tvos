import XCTest
@testable import AntresolKit

final class ProfileSwitchTests: XCTestCase {
    private let base = URL(string: "http://tv.test:8420")!

    func testPickingTheCurrentProfileReturnsWithoutPassword() {
        let admin = User(id: 1, name: "Admin", avatar: "grad-1", hasPassword: true)
        let change = ProfileSwitch(from: admin)
        XCTAssertTrue(change.returnsToCurrent(picking: 1))
        XCTAssertFalse(change.returnsToCurrent(picking: 2))
    }

    func testOnlyAPasswordProfileTokenIsRevokedAfterAnotherSignsIn() {
        let admin = ProfileSwitch(from: User(id: 1, name: "Admin", avatar: "grad-1", hasPassword: true))
        XCTAssertTrue(admin.revokesLeftToken(signedInAs: 2))
        XCTAssertFalse(admin.revokesLeftToken(signedInAs: 1))
        let kid = ProfileSwitch(from: User(id: 2, name: "Kid", avatar: "grad-2", hasPassword: false))
        XCTAssertFalse(kid.revokesLeftToken(signedInAs: 1))
    }

    func testA401ElsewhereIsAnExpiredSessionOnlyWhenMeSays401() async {
        let ok = MockTransport { _ in .json(#"{"id":1,"name":"Admin","avatar":"grad-1"}"#) }
        let okClient = APIClient(baseURL: base, token: "tok", transport: ok)
        let expiredOk = await okClient.sessionExpired()
        XCTAssertFalse(expiredOk)
        XCTAssertEqual(ok.requests.map(\.pathAndQuery), ["/api/me"])
        XCTAssertEqual(ok.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let gone = MockTransport { _ in .json(#"{"error":"Sign in required"}"#, status: 401) }
        let expiredGone = await APIClient(baseURL: base, token: "tok", transport: gone).sessionExpired()
        XCTAssertTrue(expiredGone)

        let busy = MockTransport { _ in .json(#"{"error":"busy"}"#, status: 503) }
        let expiredBusy = await APIClient(baseURL: base, token: "tok", transport: busy).sessionExpired()
        XCTAssertFalse(expiredBusy)
    }
}

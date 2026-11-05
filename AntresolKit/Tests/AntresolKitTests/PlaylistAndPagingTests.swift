import Foundation
import XCTest
@testable import AntresolKit

final class PlaylistEditingTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(PlaylistEditing.normalizedName("  Road Trip \n"), "Road Trip")
        XCTAssertNil(PlaylistEditing.normalizedName(" \n "))
    }

    func testMoveOrderMatchesTheServerPermutation() {
        // order[i] is the old position placed at new position i.
        XCTAssertEqual(PlaylistEditing.moveOrder(from: 0, to: 2, count: 3), [1, 2, 0])
        XCTAssertEqual(PlaylistEditing.moveOrder(from: 2, to: 0, count: 3), [2, 0, 1])
        XCTAssertEqual(PlaylistEditing.moveOrder(from: 1, to: 2, count: 4), [0, 2, 1, 3])
        XCTAssertNil(PlaylistEditing.moveOrder(from: 1, to: 1, count: 3))
        XCTAssertNil(PlaylistEditing.moveOrder(from: 0, to: 3, count: 3))
        XCTAssertNil(PlaylistEditing.moveOrder(from: -1, to: 0, count: 3))

        let tracks = ["a", "b", "c"]
        XCTAssertEqual(PlaylistEditing.apply(order: [2, 0, 1], to: tracks), ["c", "a", "b"])
        XCTAssertEqual(PlaylistEditing.apply(order: [0, 0, 1], to: tracks), tracks, "not a permutation")
        XCTAssertEqual(PlaylistEditing.apply(order: [0, 1], to: tracks), tracks)
    }

    func testRemoving() {
        XCTAssertEqual(PlaylistEditing.removing(positions: [1, 3], from: ["a", "b", "c", "d"]), ["a", "c"])
        XCTAssertEqual(PlaylistEditing.removing(positions: [9], from: ["a"]), ["a"])
    }

    func testUpdateBodies() async throws {
        let transport = MockTransport { _ in .json(#"{"id": 4, "name": "Mix"}"#) }
        let client = APIClient(baseURL: URL(string: "http://tv.local:8420")!, token: "t", transport: transport)
        _ = try await client.updatePlaylist(id: 4, .move(from: 0, to: 1, count: 2)!)
        _ = try await client.updatePlaylist(id: 4, .remove(positions: [3]))
        _ = try await client.updatePlaylist(id: 4, .append([15, 16]))
        _ = try await client.updatePlaylist(id: 4, .rename(to: "Mix"))
        let bodies = transport.requests.map { $0.bodyJSON ?? [:] }
        XCTAssertEqual(transport.requests.first?.httpMethod, "PATCH")
        XCTAssertEqual(transport.requests.first?.pathAndQuery, "/api/music/playlists/4")
        XCTAssertEqual(bodies[0]["order"] as? [Int], [1, 0])
        XCTAssertEqual(bodies[1]["remove"] as? [Int], [3])
        XCTAssertEqual(bodies[2]["append"] as? [Int], [15, 16])
        XCTAssertEqual(bodies[3]["name"] as? String, "Mix")
        XCTAssertEqual(bodies[3].count, 1, "unset fields are left out")
    }
}

private struct Song: Decodable, Identifiable, Sendable, Equatable {
    let id: Int
}

/// Records fetches and sleeps; fails the scripted attempts.
private final class PageServer: @unchecked Sendable {
    let all: [Song]
    private let state = Locked<(requests: [Int], sleeps: [Duration], failures: [Int: [Error]])>(([], [], [:]))

    init(count: Int, failures: [Int: [Error]] = [:]) {
        all = (1...count).map(Song.init)
        state.withLock { $0.failures = failures }
    }

    var requests: [Int] { state.current.requests }
    var sleeps: [Duration] { state.current.sleeps }

    func fetch(offset: Int, limit: Int) throws -> Page<Song> {
        let failure: Error? = state.withLock { state in
            state.requests.append(offset)
            guard var pending = state.failures[offset], !pending.isEmpty else { return nil }
            let error = pending.removeFirst()
            state.failures[offset] = pending
            return error
        }
        if let failure { throw failure }
        return Page(items: Array(all.dropFirst(offset).prefix(limit)), total: all.count)
    }

    func sleep(_ duration: Duration) {
        state.withLock { $0.sleeps.append(duration) }
    }

    func pages(after loaded: Int, pageSize: Int = 4) -> RemainingPages<Song> {
        RemainingPages(
            after: Array(all.prefix(loaded)), total: all.count, pageSize: pageSize,
            sleep: { [self] in sleep($0) },
            fetch: { [self] in try fetch(offset: $0, limit: $1) }
        )
    }
}

final class RemainingPagesTests: XCTestCase {
    func testDeliversEveryRemainingPageInOrder() async throws {
        let server = PageServer(count: 10)
        var delivered: [Song] = []
        try await server.pages(after: 3).run { batch in
            delivered += batch
            return true
        }
        XCTAssertEqual(delivered.map(\.id), Array(4...10))
        XCTAssertEqual(server.requests, [3, 7])
        XCTAssertTrue(server.pages(after: 10).isEmpty)
    }

    func testRetriesFailedPages() async throws {
        let server = PageServer(count: 9, failures: [
            5: [APIError.transport("offline"), APIError.server(status: 503, message: nil, code: nil, retryAfter: 5)],
        ])
        var delivered: [Int] = []
        try await server.pages(after: 1).run { batch in
            delivered += batch.map(\.id)
            return true
        }
        XCTAssertEqual(delivered, Array(2...9))
        XCTAssertEqual(server.requests, [1, 5, 5, 5])
        XCTAssertEqual(server.sleeps, [.seconds(1), .seconds(5)], "Retry-After stretches the second wait")
    }

    func testGivesUpAfterTheLastRetryAndOnClientErrors() async throws {
        let offline = PageServer(count: 9, failures: [5: Array(repeating: APIError.transport("offline"), count: 4)])
        var delivered: [Int] = []
        do {
            try await offline.pages(after: 1).run { batch in
                delivered += batch.map(\.id)
                return true
            }
            XCTFail("expected the last error")
        } catch let error as APIError {
            XCTAssertEqual(error, .transport("offline"))
        }
        XCTAssertEqual(delivered, [2, 3, 4, 5], "pages before the failure stay delivered")
        XCTAssertEqual(offline.sleeps.count, 3)

        let signedOut = PageServer(count: 9, failures: [1: [APIError.unauthorized(message: nil)]])
        do {
            try await signedOut.pages(after: 1).run { _ in true }
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(signedOut.requests, [1], "a 401 is not retried")
        }
    }

    func testSkipsDuplicatesAndStopsWhenAsked() async throws {
        // A song added at the top of the library while paging shifts later pages by one.
        let library = (0...8).map(Song.init)
        let loaded = Array(library[1...4])
        let pages = RemainingPages<Song>(after: loaded, total: 8, pageSize: 4) { offset, limit in
            Page(items: Array(library.dropFirst(offset).prefix(limit)), total: library.count)
        }
        var delivered: [Int] = []
        try await pages.run { batch in
            delivered += batch.map(\.id)
            return true
        }
        XCTAssertEqual(delivered, [5, 6, 7, 8])

        let server = PageServer(count: 20)
        var calls = 0
        try await server.pages(after: 0).run { _ in
            calls += 1
            return false
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(server.requests, [0])
    }
}

final class DeviceListTests: XCTestCase {
    func testDisplayOrder() throws {
        let json = """
        {"items": [
          {"id": 1, "name": "Old", "lastSeen": "2026-11-01T10:00:00Z"},
          {"id": 2, "name": "Unknown", "lastSeen": ""},
          {"id": 3, "name": "This", "lastSeen": "2026-10-01T10:00:00Z", "current": true},
          {"id": 4, "name": "Recent", "lastSeen": "2026-11-04T20:08:28Z"},
          {"id": 5, "name": "Also unknown"}
        ]}
        """
        let devices = try JSONDecoder().decode(ItemsEnvelope<DeviceSession>.self, from: Data(json.utf8)).items
        XCTAssertEqual(DeviceSession.displayOrder(devices).map(\.name), ["This", "Recent", "Old", "Also unknown", "Unknown"])
        XCTAssertNotNil(devices[3].lastSeenDate)
        XCTAssertNil(devices[1].lastSeenDate)
    }
}

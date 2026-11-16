import Foundation
import XCTest
@testable import AntresolKit

final class ConcurrencyLimiterTests: XCTestCase {
    /// Twenty pieces of work through two slots: all of them run, never more than two at once.
    func testNeverMoreThanTheLimitAtOnce() async {
        let limiter = ConcurrencyLimiter(limit: 2)
        let counts = Locked((running: 0, peak: 0, done: 0))
        await withTaskGroup(of: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    await limiter.run {
                        counts.withLock {
                            $0.running += 1
                            $0.peak = max($0.peak, $0.running)
                        }
                        Thread.sleep(forTimeInterval: 0.005)
                        counts.withLock {
                            $0.running -= 1
                            $0.done += 1
                        }
                        return index
                    }
                }
            }
            var sum = 0
            for await value in group { sum += value }
            XCTAssertEqual(sum, (0..<20).reduce(0, +), "every piece of work returns its own result")
        }
        XCTAssertEqual(counts.current.done, 20)
        XCTAssertEqual(counts.current.peak, 2)
        XCTAssertEqual(counts.current.running, 0)
    }

    /// A throwing piece of work gives its slot back.
    func testAThrowingWorkFreesItsSlot() async {
        struct Failure: Error {}
        let limiter = ConcurrencyLimiter(limit: 1)
        do {
            try await limiter.run { throw Failure() }
            XCTFail("the error is passed on")
        } catch {}
        let value = await limiter.run { 7 }
        XCTAssertEqual(value, 7)
    }

    func testTheLimitIsAtLeastOne() async {
        let limiter = ConcurrencyLimiter(limit: 0)
        XCTAssertEqual(limiter.limit, 1)
        let value = await limiter.run { "ran" }
        XCTAssertEqual(value, "ran")
    }
}

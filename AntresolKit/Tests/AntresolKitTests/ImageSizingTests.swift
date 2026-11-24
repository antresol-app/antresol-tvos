import Foundation
import XCTest
@testable import AntresolKit

/// `ServerURLs.image(_:width:)`: the server's own images are asked for at the smallest of its
/// width steps that is wide enough; everything else stays as it was.
final class ImageSizingTests: XCTestCase {
    let urls = ServerURLs(baseURL: URL(string: "http://192.168.1.10:8420")!)

    private func image(_ path: String, _ width: Int?) -> String? {
        urls.image(path, width: width)?.absoluteString
    }

    func testWidthPicksTheSmallestStepThatIsWideEnough() {
        let path = "/api/images/local/19/poster"
        let base = "http://192.168.1.10:8420/api/images/local/19/poster"
        XCTAssertEqual(image(path, 1), base + "?w=160")
        XCTAssertEqual(image(path, 160), base + "?w=160")
        XCTAssertEqual(image(path, 161), base + "?w=240")
        XCTAssertEqual(image(path, 600), base + "?w=640")
        XCTAssertEqual(image(path, 1920), base + "?w=1920")
    }

    func testWithoutWidthOrPastTheLargestStepTheImageIsTheOriginal() {
        let path = "/api/images/local/19/poster"
        let base = "http://192.168.1.10:8420/api/images/local/19/poster"
        XCTAssertEqual(image(path, nil), base)
        XCTAssertEqual(image(path, 1921), base)
        XCTAssertEqual(image(path, 3840), base)
    }

    func testBareNamesAreServerImages() {
        XCTAssertEqual(image("abc def.jpg", 300), "http://192.168.1.10:8420/api/images/abc%20def.jpg?w=320")
        XCTAssertEqual(image("/api/images/cast/x.jpg", 300), "http://192.168.1.10:8420/api/images/cast/x.jpg?w=320")
        XCTAssertEqual(image("/api/images/art/x.jpg", 300), "http://192.168.1.10:8420/api/images/art/x.jpg?w=320")
    }

    func testBasePathIsKept() {
        let proxied = ServerURLs(baseURL: URL(string: "https://example.com/antresol/")!)
        XCTAssertEqual(proxied.image("/api/images/x.jpg", width: 500)?.absoluteString, "https://example.com/antresol/api/images/x.jpg?w=640")
    }

    func testOtherPathsAreNotSized() {
        // a video frame has one size
        XCTAssertEqual(image("/api/images/frame/42", 800), "http://192.168.1.10:8420/api/images/frame/42")
        // a path with its own query (the server's sizing is for the plain image)
        XCTAssertEqual(image("/api/images/x.jpg?v=3", 800), "http://192.168.1.10:8420/api/images/x.jpg?v=3")
        // not an image file of the server
        XCTAssertEqual(image("/api/profiles/3/photo?v=17", 160), "http://192.168.1.10:8420/api/profiles/3/photo?v=17")
        // another host
        XCTAssertEqual(image("https://cdn.example.com/a.jpg", 300), "https://cdn.example.com/a.jpg")
        XCTAssertNil(image("", 300))
        XCTAssertNil(image("  ", 300))
    }

    func testTheStepsAreTheServers() {
        // internal/api/images.go `imageWidths`
        XCTAssertEqual(ServerURLs.imageWidths, [160, 240, 320, 480, 640, 960, 1280, 1920])
        XCTAssertEqual(ServerURLs.imageWidthStep(481), 640)
        XCTAssertNil(ServerURLs.imageWidthStep(1921))
    }
}

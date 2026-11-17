import Foundation
import XCTest
@testable import AntresolKit

final class URLBuilderTests: XCTestCase {
    let urls = ServerURLs(baseURL: URL(string: "http://192.168.1.10:8420")!)

    func testImages() {
        XCTAssertEqual(urls.image("/api/images/local/19/poster")?.absoluteString, "http://192.168.1.10:8420/api/images/local/19/poster")
        XCTAssertNil(urls.image(""))
        XCTAssertEqual(urls.image("https://cdn.example.com/a.jpg")?.absoluteString, "https://cdn.example.com/a.jpg")
        XCTAssertEqual(urls.image("abc def.jpg")?.absoluteString, "http://192.168.1.10:8420/api/images/abc%20def.jpg")
    }

    func testBasePathIsKept() {
        let proxied = ServerURLs(baseURL: URL(string: "https://example.com/antresol/")!)
        XCTAssertEqual(proxied.image("/api/images/x.jpg")?.absoluteString, "https://example.com/antresol/api/images/x.jpg")
    }

    func testMediaURLs() throws {
        XCTAssertEqual(urls.stream(fileId: 12, mediaKey: "v1.2.1.9.abc")?.absoluteString, "http://192.168.1.10:8420/api/stream/12?mk=v1.2.1.9.abc")
        XCTAssertEqual(urls.stream(fileId: 12, mediaKey: nil)?.absoluteString, "http://192.168.1.10:8420/api/stream/12")
        XCTAssertEqual(
            urls.trackStream(trackId: 15, mediaKey: "k")?.absoluteString,
            "http://192.168.1.10:8420/api/tracks/15/stream?accept=aac%2Cmp3%2Calac%2Cflac%2Cwav%2Caiff&mk=k"
        )
        XCTAssertEqual(
            urls.subtitle("/api/subs/12/1000.vtt?src=b70596c2")?.absoluteString,
            "http://192.168.1.10:8420/api/subs/12/1000.vtt?src=b70596c2"
        )
        let play = try Samples.decode(PlayResponse.self, "play-mkv-hls.json")
        XCTAssertEqual(urls.playback(play, mediaKey: "k")?.absoluteString, "http://192.168.1.10:8420/api/hls/d4efc029ebb8590d/index.m3u8?mk=k")
    }

    func testQueryEncodingIsStrict() {
        let url = urls.url(path: "/api/search", query: [URLQueryItem(name: "q", value: "R&B + rock")])
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.10:8420/api/search?q=R%26B%20%2B%20rock")
    }

    func testServerAddress() {
        XCTAssertEqual(ServerAddress.normalize("192.168.1.10")?.absoluteString, "http://192.168.1.10:8420")
        XCTAssertEqual(ServerAddress.normalize(" nas.local:9000/ ")?.absoluteString, "http://nas.local:9000")
        XCTAssertEqual(ServerAddress.normalize("https://media.example.com/api/")?.absoluteString, "https://media.example.com")
        XCTAssertEqual(ServerAddress.normalize("HTTP://Box:8420")?.absoluteString, "http://Box:8420")
        XCTAssertNil(ServerAddress.normalize(""))
        XCTAssertNil(ServerAddress.normalize("ftp://x"))
        XCTAssertNil(ServerAddress.normalize("two words"))
        XCTAssertEqual(ServerAddress.displayName(URL(string: "http://nas.local:8420")!), "nas.local:8420")
    }

    func testHLSSessionID() {
        XCTAssertEqual(HLSSessionID.parse("/api/hls/abc123/index.m3u8"), "abc123")
        XCTAssertEqual(HLSSessionID.parse("http://h:8420/api/hls/abc123/index.m3u8?mk=x"), "abc123")
        XCTAssertNil(HLSSessionID.parse("/api/stream/12"))
        XCTAssertNil(HLSSessionID.parse("hls/abc123/index.m3u8"))
    }
}

final class PlaybackLogicTests: XCTestCase {
    func testPlaybackSourceTimeline() throws {
        let hls = try Samples.decode(PlayResponse.self, "play-transcode-quality.json")
        let source = PlaybackSource(response: hls, url: URL(string: "http://x/a.m3u8")!)
        XCTAssertEqual(source.timelineOffset, 10)
        XCTAssertEqual(source.initialPlayerSeek, 0)
        XCTAssertEqual(source.filePosition(playerTime: 5), 15)
        XCTAssertEqual(source.playerTime(filePosition: 15), 5)
        XCTAssertFalse(source.canSeekInPlayer(toFilePosition: 5))
        XCTAssertTrue(source.canSeekInPlayer(toFilePosition: 30))

        var direct = try Samples.decode(PlayResponse.self, "play-direct.json")
        direct.startSec = 42
        let directSource = PlaybackSource(response: direct, url: URL(string: "http://x/s")!)
        XCTAssertEqual(directSource.timelineOffset, 0)
        XCTAssertEqual(directSource.initialPlayerSeek, 42)
        XCTAssertTrue(directSource.canSeekInPlayer(toFilePosition: 0))

        var full = hls
        full.startSec = 0
        let fullSource = PlaybackSource(response: full, url: URL(string: "http://x/a.m3u8")!, startPosition: 95)
        XCTAssertEqual(fullSource.initialPlayerSeek, 95)
    }

    func testUpNext() throws {
        // Seasons 1 (episodes 4, 5) and 2 (episode 12).
        let series = try Samples.decode(ItemDetail.self, "item-series.json")
        XCTAssertEqual(UpNext.episode(after: 4, in: series.seasons)?.id, 5)
        XCTAssertEqual(UpNext.episode(after: 5, in: series.seasons)?.id, 12)
        XCTAssertNil(UpNext.episode(after: 12, in: series.seasons))
        XCTAssertNil(UpNext.episode(after: -1, in: series.seasons))

        XCTAssertEqual(UpNext.proposalTime(durationSec: 2400), 2375)
        XCTAssertEqual(UpNext.proposalTime(durationSec: 60), 48)
        XCTAssertNil(UpNext.proposalTime(durationSec: 0))
        XCTAssertTrue(UpNext.isFinished(positionSec: 56, durationSec: 60))
        XCTAssertFalse(UpNext.isFinished(positionSec: 30, durationSec: 60))
    }

    func testScrobbleThreshold() {
        XCTAssertEqual(ScrobblePolicy.thresholdSeconds(durationMs: 20000), 10)
        XCTAssertEqual(ScrobblePolicy.thresholdSeconds(durationMs: 240_000), 30)
        XCTAssertEqual(ScrobblePolicy.thresholdSeconds(durationMs: 0), 30)
    }

    func testWebVTT() {
        let vtt = """
        WEBVTT

        1
        00:00:01.000 --> 00:00:03.500 align:start
        <i>Hello</i> &amp; welcome

        00:04.000 --> 00:06.000
        Line one
        Line two

        NOTE comment only
        """
        let cues = WebVTT.parse(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], SubtitleCue(start: 1, end: 3.5, text: "Hello & welcome"))
        XCTAssertEqual(cues[1].text, "Line one\nLine two")
        XCTAssertEqual(WebVTT.cue(at: 5, in: cues)?.start, 4)
        XCTAssertNil(WebVTT.cue(at: 3.6, in: cues))

        let shifted = WebVTT.shift(cues, by: 2)
        XCTAssertEqual(shifted[0].start, 0)
        XCTAssertEqual(shifted[0].end, 1.5)
        XCTAssertEqual(WebVTT.shift(cues, by: 4).count, 1)
        XCTAssertEqual(WebVTT.timestamp("01:02:03,5"), 3723.5)
    }

    func testTimestamps() throws {
        let nanos = try XCTUnwrap(Timestamp.parse("2026-11-04T20:05:27.617429922Z"))
        let whole = try XCTUnwrap(Timestamp.parse("2026-11-04T20:05:27Z"))
        XCTAssertEqual(nanos.timeIntervalSince(whole), 0.617429922, accuracy: 0.000001)
        XCTAssertNil(Timestamp.parse(nil))
        XCTAssertNil(Timestamp.parse("yesterday"))
        XCTAssertEqual(Timestamp.parse(Timestamp.format(whole)), whole)
    }

    func testDeviceIDValidation() {
        XCTAssertTrue(DeviceInfo.isValidID("3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        XCTAssertFalse(DeviceInfo.isValidID("short"))
        XCTAssertFalse(DeviceInfo.isValidID("has space in it"))
        XCTAssertFalse(DeviceInfo.isValidID("ünïcödé-ïd"))
        XCTAssertFalse(DeviceInfo.isValidID(String(repeating: "a", count: 65)))
    }

    func testAvatarPresets() {
        XCTAssertEqual(AvatarPreset(value: "grad-1").colors.from, 0x5E5CE6)
        XCTAssertEqual(AvatarPreset(value: "unknown"), .grad8)
        XCTAssertEqual(AvatarPreset.allCases.count, 8)
    }

    func testLanguageNormalization() {
        XCTAssertEqual(APIClient.normalizeLanguage("ru-RU"), "ru")
        XCTAssertEqual(APIClient.normalizeLanguage("de"), "en")
    }
}

/// The size artwork is decoded to follows the screen's scale, and full-screen art never
/// gets fewer pixels than a 1080p screen has.
final class ArtworkPixelsTests: XCTestCase {
    func testArtworkFollowsTheScreensScale() {
        // A poster 300 points wide (600 pixels of a 2x screen).
        XCTAssertEqual(ArtworkPixels.longestSide(maxAt2x: 600, scale: 2), 600)
        XCTAssertEqual(ArtworkPixels.longestSide(maxAt2x: 600, scale: 1), 300)
        XCTAssertEqual(ArtworkPixels.longestSide(maxAt2x: 175, scale: 1), 88, "rounded up")
    }

    func testFullScreenArtIsNeverBelowA1080pScreensPixels() {
        let width = ArtworkPixels.screenWidth
        XCTAssertEqual(width, 1920)
        // 1080p: a pixel of the picture for each of the screen's (it was 960 without the floor).
        XCTAssertEqual(ArtworkPixels.longestSide(maxAt2x: width, atLeast: width, scale: 1), 1920)
        XCTAssertEqual(ArtworkPixels.longestSide(maxAt2x: width, scale: 1), 960)
        // 4K: the same 1920, not the screen's 3840.
        XCTAssertEqual(ArtworkPixels.longestSide(maxAt2x: width, atLeast: width, scale: 2), 1920)
        // The floor only raises.
        XCTAssertEqual(ArtworkPixels.longestSide(maxAt2x: 600, atLeast: 100, scale: 2), 600)
    }
}

/// One guide request at a time, and none of them outlives a start-over.
final class RequestGateTests: XCTestCase {
    func testARequestBegunBeforeAResetIsStale() throws {
        var gate = RequestGate()
        let page = try XCTUnwrap(gate.begin())
        XCTAssertNil(gate.begin(), "one at a time")
        // The guide is started over while the page is on its way: the first window may
        // be asked for at once, and the late page's answer is not used.
        gate.reset()
        let first = try XCTUnwrap(gate.begin(), "a stale request does not block the new one")
        XCTAssertFalse(gate.finish(page))
        XCTAssertTrue(gate.isBusy, "the stale answer did not end the new request")
        XCTAssertTrue(gate.finish(first))
        XCTAssertFalse(gate.isBusy)
        // Without a reset: the answer is used and the next request may begin.
        let next = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.finish(next))
        XCTAssertNotNil(gate.begin())
    }
}

#if canImport(ImageIO)
import ImageIO

/// A cached picture is thrown away only when the file itself cannot be decoded.
final class ArtworkDecodingTests: XCTestCase {
    /// A PNG of plain noise-free colour, `side` pixels square.
    private func png(side: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side / 3))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testAGoodFileDecodesAtAnySizeAndIsKept() throws {
        let data = try png(side: 256)
        XCTAssertTrue(ArtworkDecoding.isImage(data))
        XCTAssertEqual(ArtworkDecoding.thumbnail(data, maxPixelSize: 96)?.width, 96)
        XCTAssertEqual(ArtworkDecoding.thumbnail(data, maxPixelSize: 1920)?.width, 256, "never scaled up")
        // Whatever made the large decode fail, this file is not the reason.
        XCTAssertFalse(ArtworkDecoding.isUndecodable(data))
    }

    /// The header is whole (ImageIO takes the file for an image, so it reached the disk
    /// cache), the picture is not there: such a file is thrown away.
    func testAFileWithOnlyItsHeaderIsThrownAway() throws {
        let data = try png(side: 256)
        // The signature and the IHDR chunk (8 + 25 bytes), then nothing.
        let header = data.prefix(33)
        XCTAssertTrue(ArtworkDecoding.isImage(header), "the header alone is recognised")
        XCTAssertNil(ArtworkDecoding.thumbnail(header, maxPixelSize: 1920))
        XCTAssertTrue(ArtworkDecoding.isUndecodable(header))
        // Not an image at all.
        XCTAssertFalse(ArtworkDecoding.isImage(Data("<html>".utf8)))
        XCTAssertTrue(ArtworkDecoding.isUndecodable(Data("<html>".utf8)))
    }
}
#endif

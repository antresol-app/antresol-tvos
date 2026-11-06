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

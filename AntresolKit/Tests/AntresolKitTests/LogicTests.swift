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
            "http://192.168.1.10:8420/api/tracks/15/stream?accept=aac%2Cmp3%2Calac%2Cflac&mk=k"
        )
        XCTAssertEqual(
            urls.audio(fileId: 11, accept: [.mp3], format: .aac, startSec: 12.5, mediaKey: "k")?.absoluteString,
            "http://192.168.1.10:8420/api/audio/11?accept=mp3&format=aac&t=12.5&mk=k"
        )
        XCTAssertEqual(urls.comicPage(fileId: 13, index: 0)?.absoluteString, "http://192.168.1.10:8420/api/comics/13/page/0")
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
    }
}

final class PlaybackLogicTests: XCTestCase {
    func testAudiobookTimeline() {
        let timeline = AudiobookTimeline(files: [BookFile(id: 1, durationMs: 30041), BookFile(id: 2, durationMs: 30000)])
        XCTAssertEqual(timeline.totalMs, 60041)
        XCTAssertEqual(timeline.locate(bookMs: 0), .init(partIndex: 0, offsetMs: 0))
        XCTAssertEqual(timeline.locate(bookMs: 30040), .init(partIndex: 0, offsetMs: 30040))
        XCTAssertEqual(timeline.locate(bookMs: 30041), .init(partIndex: 1, offsetMs: 0))
        XCTAssertEqual(timeline.locate(bookMs: 45000), .init(partIndex: 1, offsetMs: 14959))
        XCTAssertEqual(timeline.locate(bookMs: 99999), .init(partIndex: 1, offsetMs: 30000))
        XCTAssertEqual(timeline.bookMs(partIndex: 1, offsetMs: 1000), 31041)
        XCTAssertNil(AudiobookTimeline(files: []).locate(bookMs: 0))
    }

    func testChapterLookup() throws {
        let book = try Samples.decode(BookDetail.self, "book-audiobook.json")
        XCTAssertEqual(AudiobookTimeline.chapter(at: 0, in: book.chapters)?.title, "Opening")
        XCTAssertEqual(AudiobookTimeline.chapter(at: 25000, in: book.chapters)?.title, "Middle")
        XCTAssertEqual(AudiobookTimeline.chapter(at: 59999, in: book.chapters)?.title, "Ending")
    }

    func testAudiobookResume() {
        XCTAssertEqual(ResumePolicy.audiobookStartMs(positionMs: 20000, durationMs: 600_000, finished: false), 20000)
        XCTAssertEqual(ResumePolicy.audiobookStartMs(positionMs: 20000, durationMs: 600_000, finished: true), 0)
        XCTAssertEqual(ResumePolicy.audiobookStartMs(positionMs: 590_000, durationMs: 600_000, finished: false), 0)
        XCTAssertEqual(ResumePolicy.audiobookStartMs(positionMs: 3_500_000, durationMs: 3_600_000, finished: false), 3_500_000)
        XCTAssertEqual(ResumePolicy.audiobookStartMs(positionMs: 3_580_000, durationMs: 3_600_000, finished: false), 0)
    }

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
    }

    func testComicProgress() {
        let update = ComicProgress.update(pageIndex: 1, count: 3)
        XCTAssertEqual(update.locator, "page:2")
        XCTAssertEqual(update.fraction!, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(ComicProgress.pageIndex(locator: "page:2"), 1)
        XCTAssertNil(ComicProgress.pageIndex(locator: "epubcfi(/6/2)"))
        XCTAssertNil(ComicProgress.pageIndex(locator: "page:0"))
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

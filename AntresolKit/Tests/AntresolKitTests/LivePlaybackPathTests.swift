import Foundation
import XCTest
@testable import AntresolKit

/// The live banner's playback path, codec names, the bad-source memory and the fallback steps.
final class LivePlaybackPathTests: XCTestCase {
    func testSourceDecodesFormatAndRelay() throws {
        let json = Data("""
        {"url":"http://p.example.test/live/1.m3u8","format":"hls","relay":"/api/channels/live/ext/5/0/relay",
         "fallbacks":[{"url":"/api/channels/live/ext/5/1","format":"ts"}],"unsupported":[]}
        """.utf8)
        let stream = try JSONDecoder().decode(ChannelStream.self, from: json)
        XCTAssertEqual(stream.primary.format, "hls")
        XCTAssertEqual(stream.primary.relay, "/api/channels/live/ext/5/0/relay")
        XCTAssertEqual(stream.fallbacks.first?.format, "ts")
        XCTAssertEqual(stream.fallbacks.first?.relay, "")
    }

    func testExternalPath() {
        let direct = LivePlaybackPath.external(StreamSource(url: "http://user:pw@cdn.example.test:8080/x/y?token=1", format: "ts"), attempt: 0, count: 2)
        XCTAssertEqual(direct.route, .direct(host: "cdn.example.test"), "the host only, never credentials or the path")
        XCTAssertEqual(direct.format, "MPEG-TS")
        XCTAssertEqual(direct.attempt, 1)
        XCTAssertTrue(direct.showsAttempt)
        let hidden = LivePlaybackPath.external(StreamSource(url: "/api/channels/live/ext/5/1"), attempt: 1, count: 2)
        XCTAssertEqual(hidden.route, .antresol)
        XCTAssertNil(hidden.format)
        XCTAssertEqual(LivePlaybackPath.formatName("", url: "http://a.test/s/index.m3u8"), "HLS")
        XCTAssertFalse(LivePlaybackPath.external(StreamSource(url: "http://a.test/1"), attempt: 0, count: 1).showsAttempt)
        var path = LivePlaybackPath(route: .antresol, format: "HLS", video: "H.264", audio: "AAC")
        XCTAssertEqual(path.technical, ["HLS", "H.264 / AAC"])
        path.video = nil
        path.format = nil
        XCTAssertEqual(path.technical, ["AAC"])
    }

    func testCodecNames() {
        XCTAssertEqual(MediaCodecName.name(fourCC: "avc1"), "H.264")
        XCTAssertEqual(MediaCodecName.name(fourCC: "hvc1"), "HEVC")
        XCTAssertEqual(MediaCodecName.name(fourCC: "ac-3"), "AC-3")
        XCTAssertEqual(MediaCodecName.name(fourCC: ".mp2"), "MP2")
        XCTAssertNil(MediaCodecName.name(fourCC: "zzzz"))
        XCTAssertEqual(MediaCodecName.name(hlsCodec: "mp4a.40.2"), "AAC")
        XCTAssertEqual(MediaCodecName.name(hlsCodec: "mp4a.6B"), "MP3")
        XCTAssertFalse(MediaCodecName.isPlayableAudio("MP2"))
        XCTAssertTrue(MediaCodecName.isPlayableAudio("AC-3"))
        let codecs = StreamCodecs(master: """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.64001f,ac-3"
        720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=400000,CODECS="hvc1.1.6.L93.B0,mp4a.40.2"
        480.m3u8
        """)
        XCTAssertEqual(codecs, StreamCodecs(video: "H.264", audio: "AC-3"), "the first variant's")
        XCTAssertEqual(StreamCodecs(master: "#EXTM3U\n#EXTINF:6,\nseg1.ts\n"), StreamCodecs())
    }

    func testBadSourcesGoLastAndExpire() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let memory = ExternalSourceMemory(defaults: defaults)
        let a = StreamSource(url: "http://a.test/1"), b = StreamSource(url: "http://b.test/1"), c = StreamSource(url: "/api/channels/live/ext/7/2")
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(memory.ordered([a, b, c], channel: 7, now: now), [a, b, c])
        memory.markBad(a, channel: 7, now: now)
        XCTAssertEqual(memory.ordered([a, b, c], channel: 7, now: now), [b, c, a])
        XCTAssertEqual(memory.ordered([a, b, c], channel: 8, now: now), [a, b, c], "per channel")
        XCTAssertTrue(memory.isBad(a, channel: 7, now: now))
        // the URL is not stored, only its digest
        let stored = defaults.dictionary(forKey: "tv.external.badSources.7") ?? [:]
        XCTAssertFalse(stored.keys.contains { $0.contains("a.test") })
        XCTAssertEqual(memory.ordered([a, b, c], channel: 7, now: now.addingTimeInterval(ExternalSourceMemory.lifetime + 1)), [a, b, c], "a mark expires")
        memory.markGood(a, channel: 7, now: now)
        XCTAssertEqual(memory.ordered([a, b, c], channel: 7, now: now), [a, b, c])
    }

    func testFallbackSteps() {
        XCTAssertEqual(ExternalFallback.afterFailure(attempt: 0, count: 3, silent: []), .tryNext(1))
        XCTAssertEqual(ExternalFallback.afterFailure(attempt: 2, count: 3, silent: []), .giveUp)
        XCTAssertEqual(ExternalFallback.afterFailure(attempt: 2, count: 3, silent: [1, 0]), .acceptSilent(0), "a silent picture beats nothing")
        XCTAssertEqual(ExternalFallback.afterFailure(attempt: 0, count: 1, silent: [0]), .giveUp, "the silent source itself failed")
        XCTAssertEqual(ExternalFallback.afterSilence(attempt: 0, count: 2), .tryNext(1))
        XCTAssertEqual(ExternalFallback.afterSilence(attempt: 1, count: 2), .acceptSilent(1))
    }
}

import Foundation
import XCTest
@testable import AntresolKit

/// «ТВ» external channels: what the list says about them, the order the player tries
/// their sources in, the URL it opens, the stream's own track names and the per-channel
/// memory of the viewer's pick.
final class ExternalChannelTests: XCTestCase {
    private let json = Data("""
    {"channels":[
      {"id":6,"number":12,"name":"Own","category":"Кино"},
      {"id":50,"number":100,"name":"External 1","category":"Новости","external":true,
       "logoUrl":"http://logo.example.test/1.png",
       "now":{"id":"x1-1","itemId":0,"kind":"external","title":"News","start":"2026-11-12T10:00:00Z","end":"2026-11-12T11:00:00Z"},
       "stream":{"url":"http://p1.example.test/a.m3u8","userAgent":"Agent/1.0","unsupported":[],
         "fallbacks":[{"url":"/api/channels/live/ext/50/1","unsupported":[]},
                      {"url":"http://p3.example.test/c.m3u8","unsupported":["tvos"]},
                      {"url":"https://p4.example.test/d.m3u8","referrer":"https://site.example.test/","unsupported":["web"]}]}},
      {"id":51,"number":101,"name":"Web only","external":true,
       "stream":{"url":"http://p5.example.test/e.m3u8","fallbacks":[],"unsupported":["web","tvos"]}}
    ],"lastChannel":50}
    """.utf8)

    private func list() throws -> ChannelList {
        try JSONDecoder().decode(ChannelList.self, from: json)
    }

    func testDecodesExternalChannels() throws {
        let channels = try list().channels
        let own = try XCTUnwrap(channels.first { $0.id == 6 })
        XCTAssertFalse(own.external)
        XCTAssertNil(own.stream)
        let x = try XCTUnwrap(channels.first { $0.id == 50 })
        XCTAssertTrue(x.external)
        XCTAssertEqual(x.logoUrl, "http://logo.example.test/1.png")
        XCTAssertEqual(x.now?.itemId, 0)
        XCTAssertEqual(x.now?.kind, "external")
        let stream = try XCTUnwrap(x.stream)
        XCTAssertEqual(stream.primary.headers, ["User-Agent": "Agent/1.0"])
        XCTAssertEqual(stream.fallbacks.count, 3)
        XCTAssertEqual(stream.fallbacks[2].headers, ["Referer": "https://site.example.test/"])
        // one numbered list: zapping walks from own channels into external ones
        XCTAssertEqual(Channel.neighbour(of: 6, in: channels.sorted(by: Channel.byNumber), step: 1)?.id, 50)
        // a guide row opens the list's channel, with its stream
        let row = ChannelEPG(id: 50, number: 100, name: "External 1", external: true)
        XCTAssertNil(row.channel.stream)
        XCTAssertEqual(row.channel(in: channels).stream, stream)
    }

    func testFallbackOrderOnAppleTV() throws {
        let channels = try list().channels
        let stream = try XCTUnwrap(channels.first { $0.id == 50 }?.stream)
        XCTAssertEqual(stream.playable(on: ChannelStream.tvOSTags).map(\.url),
                       ["http://p1.example.test/a.m3u8", "/api/channels/live/ext/50/1", "https://p4.example.test/d.m3u8"])
        XCTAssertTrue(try XCTUnwrap(channels.first { $0.id == 51 }?.stream).playable(on: ChannelStream.tvOSTags).isEmpty)
    }

    func testOnlyTheServersRedirectGetsTheMediaKey() throws {
        let urls = ServerURLs(baseURL: URL(string: "http://server.example.test:8420")!)
        let stream = try XCTUnwrap(try list().channels.first { $0.id == 50 }?.stream)
        XCTAssertEqual(urls.externalStream(stream.primary, mediaKey: "k1")?.absoluteString, "http://p1.example.test/a.m3u8")
        XCTAssertEqual(urls.externalStream(stream.fallbacks[0], mediaKey: "k1")?.absoluteString,
                       "http://server.example.test:8420/api/channels/live/ext/50/1?mk=k1")
        XCTAssertNil(urls.externalStream(StreamSource(url: "rtmp://p.example.test/x"), mediaKey: "k1"))
    }

    func testStreamTrackNames() {
        let master = LiveRenditions(master: """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",LANGUAGE="en",NAME="Main",URI="a1.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",LANGUAGE="fr",NAME="Commentaire",URI="a2.m3u8"
        """)
        // AVFoundation names options by language; the master tells their own names
        let entries = ExternalTracks.entries(options: [("English", "en"), ("Français", "fr")], renditions: master.audio)
        XCTAssertEqual(entries.map(\.name), ["Main", "Commentaire"])
        XCTAssertEqual(entries.map { ExternalTracks.index(of: $0) }, [0, 1])
        // no master: the options' names, two of one name told apart
        XCTAssertEqual(ExternalTracks.entries(options: [("English", "en"), ("English", "en")], renditions: []).map(\.name),
                       ["English", "English 2"])
    }

    func testTrackMemoryPerChannel() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let memory = ExternalTrackMemory(defaults: defaults)
        XCTAssertEqual(memory.selection(for: 50), LiveTrackSelection())
        var pick = LiveTrackSelection()
        pick.audio = .init(name: "Commentaire", lang: "fr")
        pick.subtitle = .some(nil)
        memory.save(pick, for: 50)
        XCTAssertEqual(memory.selection(for: 50), pick)
        XCTAssertEqual(memory.selection(for: 51), LiveTrackSelection(), "another channel keeps its own")
        // the default with nothing kept: the profile's language
        let tracks = [LiveTrack(slot: "o0", name: "Main", lang: "en"), LiveTrack(slot: "o1", name: "Commentaire", lang: "fr")]
        XCTAssertEqual(LiveTrackSelection().audio(in: tracks, prefs: PlaybackPrefs(audioLangs: ["fr"]), device: [])?.name, "Commentaire")
        XCTAssertEqual(LiveTrackSelection().audio(in: tracks, prefs: PlaybackPrefs(audioLangs: ["en"]), device: ["fr"])?.name, "Commentaire")
        XCTAssertEqual(memory.selection(for: 50).audio(in: tracks, prefs: PlaybackPrefs(audioLangs: ["en"]), device: ["en"])?.name, "Commentaire")
    }

    func testOpenedIsTheOnlyNewWrite() {
        XCTAssertTrue(ChannelService.isAllowedWrite(method: "POST", path: "/api/channels/opened"))
        XCTAssertFalse(ChannelService.isAllowedWrite(method: "POST", path: "/api/channels/50/favorite"))
        XCTAssertFalse(ChannelService.isAllowedWrite(method: "PUT", path: "/api/items/0/track-prefs"))
    }
}

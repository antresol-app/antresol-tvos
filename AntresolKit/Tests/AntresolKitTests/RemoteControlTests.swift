import Foundation
import XCTest
@testable import AntresolKit

/// The TV-style remote control of the channel list and the live player: the exclusive (adult)
/// category (only there, last), typed channel numbers, the generated channel tile's colour, and the live
/// player's default tracks from the profile's languages and the master's DEFAULT.
final class RemoteControlTests: XCTestCase {
    private func channel(_ id: Int, _ number: Int, _ categories: [String], favorite: Bool = false) -> Channel {
        Channel(id: id, number: number, name: "Channel \(number)", favorite: favorite, categories: categories)
    }

    // MARK: Exclusive (adult) category

    /// The server's contract: the adult category is `ai:adult` with `exclusive: true`, listed
    /// anywhere; the app honours any exclusive category, not a name.
    private var list: ChannelList {
        let json = #"""
        {"channels": [
          {"id": 1, "number": 1, "name": "One", "categories": ["ai:news"]},
          {"id": 2, "number": 2, "name": "Two", "favorite": true, "categories": ["ai:adult", "ai:movies"]},
          {"id": 3, "number": 3, "name": "Three", "favorite": true, "categories": ["ai:movies"]},
          {"id": 4, "number": 4, "name": "Four", "categories": ["ai:adult"]}
        ], "categories": [
          {"id": "ai:adult", "name": "Для взрослых", "kind": "ai", "count": 2, "exclusive": true},
          {"id": "ai:movies", "name": "Кино", "kind": "ai", "count": 2},
          {"id": "ai:news", "name": "Новости", "kind": "ai", "count": 1}
        ]}
        """#
        return try! JSONDecoder().decode(ChannelList.self, from: Data(json.utf8))
    }

    func testExclusiveChannelsAreOnlyInTheirCategory() {
        let channels = list.channels
        XCTAssertEqual(channels.map(\.exclusiveCategory), [nil, "ai:adult", nil, "ai:adult"])
        XCTAssertEqual(ChannelFilter.all.apply(to: channels).map(\.id), [1, 3])
        XCTAssertEqual(ChannelFilter.favorites.apply(to: channels).map(\.id), [3], "a starred adult channel stays in its category")
        XCTAssertEqual(ChannelFilter.category("ai:movies").apply(to: channels).map(\.id), [3])
        XCTAssertEqual(ChannelFilter.category("ai:adult").apply(to: channels).map(\.id), [2, 4])
        // Not by name: without `exclusive` an `ai:adult` category is like any other.
        let plain = ChannelList(channels: [channel(5, 5, ["ai:adult"])], categories: [ChannelCategory(id: "ai:adult", name: "A")])
        XCTAssertEqual(ChannelFilter.all.apply(to: plain.channels).map(\.id), [5])
        // Any exclusive category.
        let other = ChannelList(channels: [channel(6, 6, ["group:X"]), channel(7, 7, [])],
                                categories: [ChannelCategory(id: "group:X", name: "X", exclusive: true)])
        XCTAssertEqual(ChannelFilter.all.apply(to: other.channels).map(\.id), [7])
    }

    func testExclusiveCategoryIsLastWithItsOwnCount() {
        let options = ChannelFilter.options(for: list.channels, server: list.categories)
        XCTAssertEqual(options.map(\.filter), [.favorites, .all, .category("ai:movies"), .category("ai:news"), .category("ai:adult")],
                       "Favourites first, the exclusive category last whatever the server's order")
        XCTAssertEqual(options.map(\.count), [1, 2, 1, 1, 2])
        XCTAssertEqual(options.map(\.exclusive), [false, false, false, false, true])
    }

    func testZappingOutsideTheExclusiveCategorySkipsItsChannels() {
        let channels = list.channels
        let zap = ChannelFilter.all.zapList(channels, current: channels[0])
        XCTAssertEqual(zap.map(\.id), [1, 3])
        XCTAssertEqual(Channel.neighbour(of: 1, in: zap, step: 1)?.id, 3)
        XCTAssertEqual(ChannelFilter.category("ai:adult").zapList(channels, current: channels[1]).map(\.id), [2, 4])
    }

    func testTheGuideKnowsTheExclusiveCategory() throws {
        let json = #"""
        {"from": "2026-11-19T20:00:00Z", "to": "2026-11-19T22:00:00Z",
         "channels": [{"id": 1, "number": 1, "name": "One", "categories": ["ai:news"]}, {"id": 4, "number": 4, "name": "Four", "categories": ["ai:adult"]}],
         "categories": [{"id": "ai:adult", "name": "A", "kind": "ai", "exclusive": true}]}
        """#
        let window = try JSONDecoder().decode(ChannelEPGWindow.self, from: Data(json.utf8))
        XCTAssertEqual(ChannelGuideGrid(window).rows(.all).map(\.id), [1])
        // A window without `categories`: the list's marks.
        var grid = ChannelGuideGrid(ChannelEPGWindow(from: Date(), to: Date(), channels: [ChannelEPG(id: 2, number: 2, name: "Two", categories: ["ai:adult"])]))
        grid.applyLogos(from: list.channels)
        XCTAssertEqual(grid.rows(.all).map(\.id), [])
        XCTAssertEqual(grid.rows(.category("ai:adult")).map(\.id), [2])
    }

    func testTopShelfLeavesExclusiveChannelsOut() {
        let now = Date()
        let onAir = ChannelProgram(itemId: 1, title: "On", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(600))
        var channels = list.channels
        for i in channels.indices { channels[i].now = onAir }
        XCTAssertEqual(TopShelfChannels(channels: channels, at: now).entries.map(\.channel.id), [1, 3])
    }

    // MARK: Typed channel numbers

    func testNumberEntryShowsWhatFollowsAndCompletes() {
        var entry = ChannelNumberEntry(highestNumber: 250)
        XCTAssertEqual(entry.maxDigits, 3)
        XCTAssertTrue(entry.isEmpty)
        XCTAssertFalse(entry.append("0"), "a leading zero is dropped")
        XCTAssertTrue(entry.isEmpty)
        XCTAssertFalse(entry.append("2"))
        XCTAssertEqual(entry.display, "2_")
        XCTAssertFalse(entry.append("3"))
        XCTAssertEqual(entry.display, "23_")
        XCTAssertEqual(entry.number, 23)
        entry.deleteLast()
        XCTAssertEqual(entry.display, "2_")
        XCTAssertFalse(entry.append("x"), "not a digit")
        entry.append("3")
        XCTAssertTrue(entry.append("4"), "as many digits as the highest number: taken at once")
        XCTAssertEqual(entry.display, "234")
        XCTAssertTrue(entry.append("5"), "nothing past the last digit")
        XCTAssertEqual(entry.number, 234)
        XCTAssertEqual(ChannelNumberEntry(channels: []).maxDigits, 1)
        XCTAssertEqual(ChannelNumberEntry(channels: [channel(1, 9, [])]).maxDigits, 1)
        XCTAssertEqual(ChannelNumberEntry.timeout, .milliseconds(1500))
    }

    func testKeyCharactersGiveDigits() {
        XCTAssertEqual(ChannelNumberEntry.digit(in: "7"), "7")
        XCTAssertNil(ChannelNumberEntry.digit(in: "a"))
        XCTAssertNil(ChannelNumberEntry.digit(in: "12"))
        XCTAssertNil(ChannelNumberEntry.digit(in: ""))
        XCTAssertNil(ChannelNumberEntry.digit(in: "٣"), "ASCII digits only")
    }

    func testATypedNumberReachesAnExclusiveChannelOnlyFromItsCategory() {
        let list = list.channels
        XCTAssertEqual(ChannelFilter.all.channel(number: 3, in: list)?.id, 3)
        XCTAssertEqual(ChannelFilter.category("ai:news").channel(number: 3, in: list)?.id, 3, "a number is the whole list's")
        XCTAssertNil(ChannelFilter.all.channel(number: 4, in: list))
        XCTAssertNil(ChannelFilter.favorites.channel(number: 2, in: list))
        XCTAssertEqual(ChannelFilter.category("ai:adult").channel(number: 4, in: list)?.id, 4)
        XCTAssertNil(ChannelFilter.all.channel(number: 99, in: list))
    }

    // MARK: Generated tile

    func testTileGradientIsTheWebsFormula() {
        // h = h*31 + code point over the trimmed lower-cased name; grad-(h % 7 + 1).
        XCTAssertEqual(Channel.tileGradient(of: "a"), .grad7, "97 % 7 = 6")
        XCTAssertEqual(Channel.tileGradient(of: "ab"), AvatarPreset(value: "grad-\((97 * 31 + 98) % 7 + 1)"))
        XCTAssertEqual(Channel.tileGradient(of: " Первый канал "), Channel.tileGradient(of: "первый КАНАЛ"))
        var h: UInt32 = 0
        for c in "россия 1".unicodeScalars { h = h &* 31 &+ c.value }
        XCTAssertEqual(Channel(id: 1, number: 1, name: "Россия 1").tileGradient, AvatarPreset(value: "grad-\(h % 7 + 1)"))
        let long = String(repeating: "Очень длинное название канала ", count: 20)
        XCTAssertNotEqual(Channel.tileGradient(of: long), .grad8, "wraps, never the grey one")
    }

    // MARK: Live tracks: the profile's languages, the master's DEFAULT

    private let ru = LiveTrack(name: "Русский", lang: "ru")
    private let ru2 = LiveTrack(name: "LostFilm", lang: "ru")
    private let en = LiveTrack(name: "English", lang: "en")
    private let subRu = LiveTrack(name: "Русские", lang: "ru")
    private let subEn = LiveTrack(name: "English", lang: "en")

    func testTheProfilesLanguagesComeBeforeTheDevices() {
        let none = LiveTrackSelection()
        XCTAssertEqual(none.audio(in: [ru, en], prefs: PlaybackPrefs(audioLangs: ["ru"]), device: ["en-GB"]), ru)
        XCTAssertEqual(none.audio(in: [ru, en], prefs: PlaybackPrefs(audioLangs: ["en", "ru"]), device: ["ru-RU"]), en)
        XCTAssertEqual(none.audio(in: [ru, en], prefs: PlaybackPrefs(audioLangs: ["de"]), device: ["en"]), en, "then the device's")
    }

    func testTheMastersDefaultPicksWithinTheProfilesLanguage() {
        let none = LiveTrackSelection()
        // The server marks the voice the profile would pick (its favourite studio).
        XCTAssertEqual(none.audio(in: [ru, ru2, en], prefs: PlaybackPrefs(audioLangs: ["ru"]), device: [], defaultName: "LostFilm"), ru2)
        // An older server marks the first Russian voice whatever the profile: its languages win.
        XCTAssertEqual(none.audio(in: [ru, ru2, en], prefs: PlaybackPrefs(audioLangs: ["en"]), device: [], defaultName: "Русский"), en)
        // None of the profile's languages: the master's DEFAULT, not the device's.
        XCTAssertEqual(none.audio(in: [ru, en], prefs: PlaybackPrefs(audioLangs: ["de"]), device: ["en"], defaultName: "Русский"), ru)
        // A pick beats it.
        XCTAssertEqual(LiveTrackSelection(audio: .init(en)).audio(in: [ru, en], prefs: PlaybackPrefs(), device: [], defaultName: "Русский"), en)
        // A DEFAULT the programme lacks is ignored.
        XCTAssertEqual(none.audio(in: [ru, en], prefs: PlaybackPrefs(audioLangs: ["en"]), device: [], defaultName: "Gone"), en)
    }

    func testTheMastersDefaultSubtitlesAreShown() {
        let none = LiveTrackSelection()
        XCTAssertEqual(none.subtitle(in: [subRu, subEn], audio: en, prefs: PlaybackPrefs(), defaultName: "English"), subEn,
                       "the server marks subtitles only when the profile shows them")
        XCTAssertNil(none.subtitle(in: [subRu, subEn], audio: en, prefs: PlaybackPrefs(), defaultName: nil))
        XCTAssertNil(LiveTrackSelection(subtitle: .some(nil)).subtitle(in: [subRu], audio: ru, prefs: PlaybackPrefs(), defaultName: "Русские"),
                     "the viewer turned them off")
    }
}

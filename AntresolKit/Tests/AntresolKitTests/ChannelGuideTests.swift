import Foundation
import XCTest
@testable import AntresolKit

/// Filters of the one list, zapping inside a filter, the guide grid, the live player's
/// audio and subtitle defaults, and the rule that channels leave no history.
final class ChannelGuideTests: XCTestCase {
    private func channel(_ id: Int, _ number: Int, _ category: String = "", favorite: Bool = false) -> Channel {
        Channel(id: id, number: number, name: "Channel \(number)", category: category, favorite: favorite)
    }

    private func program(_ key: String, _ start: TimeInterval, _ end: TimeInterval) -> ChannelProgram {
        ChannelProgram(id: key, itemId: 1, title: key, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: Filters

    func testFilterOptionsAreAllFavouritesThenThemesByLowestNumber() {
        let channels = [channel(1, 40, "Decades"), channel(2, 10, "Genres"), channel(3, 1, "All"), channel(4, 2, "Decades"), channel(5, 3, "")]
        XCTAssertEqual(ChannelFilter.options(for: channels), [.all, .favorites, .category("All"), .category("Decades"), .category("Genres")])
        XCTAssertEqual(ChannelFilter.options(for: []), [.all, .favorites])
    }

    func testFiltersKeepTheNumberOrder() {
        let channels = [channel(1, 40, "D", favorite: true), channel(2, 10, "G"), channel(3, 1, "A", favorite: true), channel(4, 2, "D")]
        XCTAssertEqual(ChannelFilter.all.apply(to: channels).map(\.number), [1, 2, 10, 40])
        XCTAssertEqual(ChannelFilter.favorites.apply(to: channels).map(\.number), [1, 40])
        XCTAssertEqual(ChannelFilter.category("D").apply(to: channels).map(\.number), [2, 40])
        XCTAssertTrue(ChannelFilter.category("none").apply(to: channels).isEmpty)
    }

    func testZappingStaysInTheListItWasOpenedFrom() {
        let channels = [channel(1, 1, "A", favorite: true), channel(2, 2, "B"), channel(3, 3, "A"), channel(4, 4, "B", favorite: true)]
        let favourites = ChannelFilter.favorites.zapList(channels, current: channels[0])
        XCTAssertEqual(Channel.neighbour(of: 1, in: favourites, step: 1)?.id, 4)
        XCTAssertEqual(Channel.neighbour(of: 4, in: favourites, step: 1)?.id, 1, "wraps")
        XCTAssertEqual(Channel.neighbour(of: 1, in: favourites, step: -1)?.id, 4, "wraps backwards")
        let theme = ChannelFilter.category("B").zapList(channels, current: channels[1])
        XCTAssertEqual(theme.map(\.id), [2, 4])
        // A favourite just removed stays in its place, so zapping on from it is no jump.
        var unstarred = channels
        unstarred[3].favorite = false
        let kept = ChannelFilter.favorites.zapList(unstarred, current: unstarred[3])
        XCTAssertEqual(kept.map(\.id), [1, 4])
        XCTAssertEqual(Channel.neighbour(of: 4, in: kept, step: 1)?.id, 1)
    }

    func testFilterStorage() {
        for filter in [ChannelFilter.all, .favorites, .category("Кино по жанрам"), .category("a:b")] {
            XCTAssertEqual(ChannelFilter(storageKey: filter.storageKey), filter)
        }
        XCTAssertEqual(ChannelFilter(storageKey: "junk"), .all)
    }

    // MARK: Guide grid

    func testDecodesTheEPGSample() throws {
        let window = try Samples.decode(ChannelEPGWindow.self, "channel-epg.json")
        XCTAssertEqual(window.to.timeIntervalSince(window.from), 3600)
        XCTAssertEqual(window.channels.map(\.number), [1, 2, 3])
        XCTAssertTrue(window.channels[2].favorite)
        XCTAssertFalse(window.channels[0].programs.isEmpty)
        let row = window.channels[0]
        XCTAssertEqual(row.programs, row.programs.sorted { $0.start < $1.start })
        XCTAssertEqual(row.channel.name, row.name)
    }

    func testMergingWindowsKeepsOneRowPerChannel() {
        var grid = ChannelGuideGrid(ChannelEPGWindow(from: t(0), to: t(100), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [program("1-1", 0, 50), program("1-2", 50, 120)]),
            ChannelEPG(id: 2, number: 2, name: "B", programs: [program("2-1", 0, 100)]),
        ]))
        grid.merge(ChannelEPGWindow(from: t(100), to: t(200), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", favorite: true, programs: [program("1-2", 50, 120), program("1-3", 120, 200)]),
            ChannelEPG(id: 2, number: 2, name: "B", programs: [program("2-2", 100, 200)]),
        ]))
        XCTAssertEqual(grid.rows.map(\.id), [1, 2])
        XCTAssertEqual(grid.rows[0].programs.map(\.id), ["1-1", "1-2", "1-3"])
        XCTAssertTrue(grid.rows[0].favorite, "the fresh window's flags")
        XCTAssertEqual(grid.rows[1].programs.map(\.id), ["2-1", "2-2"])
        XCTAssertEqual(grid.loadedFrom, t(0))
        XCTAssertEqual(grid.loadedTo, t(200))
        // A channel gone from the list is dropped.
        grid.merge(ChannelEPGWindow(from: t(200), to: t(300), channels: [ChannelEPG(id: 2, number: 2, name: "B")]))
        XCTAssertEqual(grid.rows.map(\.id), [2])
        grid.setFavorite(true, channelId: 2)
        XCTAssertEqual(grid.rows(.favorites).map(\.id), [2])
    }

    func testARebuiltScheduleReplacesOverlappingProgrammes() {
        var grid = ChannelGuideGrid(ChannelEPGWindow(from: t(0), to: t(100), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [program("1-1", 0, 50), program("1-2", 50, 100)]),
        ]))
        grid.merge(ChannelEPGWindow(from: t(40), to: t(140), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [program("1-1", 0, 50), program("1-9", 50, 90), program("1-10", 90, 140)]),
        ]))
        XCTAssertEqual(grid.rows[0].programs.map(\.id), ["1-1", "1-9", "1-10"])
    }

    /// A film of three files, 60–180 (files 60–100, 100–140, 140–180), and the windows'
    /// edge at 120: the server names a programme after its first file inside the window
    /// and leaves out the files outside it.
    func testAProgrammeCutByTheWindowsEdgeIsOneProgramme() {
        func film(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> ChannelProgram {
            ChannelProgram(id: id, itemId: 7, title: "Film", start: t(start), end: t(end))
        }
        let before = ChannelEPGWindow(from: t(0), to: t(120), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [program("1-1", 0, 60), film("1-2", 60, 140)]),
        ])
        let after = ChannelEPGWindow(from: t(120), to: t(240), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [film("1-3", 100, 180), program("1-5", 180, 240)]),
        ])
        // Scrolling right: the film keeps its key and gets its end.
        var grid = ChannelGuideGrid(before)
        grid.merge(after)
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["1-1", "1-2", "1-5"])
        XCTAssertEqual(grid.rows[0].programs[1].start, t(60))
        XCTAssertEqual(grid.rows[0].programs[1].end, t(180))
        // Either window again changes nothing.
        let once = grid
        grid.merge(after)
        grid.merge(before)
        XCTAssertEqual(grid.rows[0].programs, once.rows[0].programs)

        // Scrolling left: the same, under the key the film had first.
        grid = ChannelGuideGrid(after)
        grid.merge(before)
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["1-1", "1-3", "1-5"])
        XCTAssertEqual(grid.rows[0].programs[1].start, t(60))
        XCTAssertEqual(grid.rows[0].programs[1].end, t(180))
        for (a, b) in zip(grid.rows[0].programs, grid.rows[0].programs.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "programmes of one channel do not overlap")
        }

        // The same film shown twice in a row is two programmes.
        grid = ChannelGuideGrid(ChannelEPGWindow(from: t(0), to: t(120), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [film("1-1", 0, 120)]),
        ]))
        grid.merge(ChannelEPGWindow(from: t(120), to: t(240), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [film("1-2", 120, 240)]),
        ]))
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["1-1", "1-2"])
    }

    /// An external (XMLTV) guide's programmes carry no item, and sloppy guides overlap:
    /// A 90–130 and C 115–150 around the windows' edge at 120 are two programmes.
    func testOverlappingExternalProgrammesAreNotJoined() throws {
        func entry(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> ChannelProgram {
            ChannelProgram(id: id, itemId: 0, kind: "external", title: id, start: t(start), end: t(end))
        }
        let before = ChannelEPGWindow(from: t(0), to: t(120), channels: [
            ChannelEPG(id: 9, number: 100, name: "X", programs: [entry("xa", 90, 130), entry("xc", 115, 150)], external: true),
        ])
        let after = ChannelEPGWindow(from: t(120), to: t(240), channels: [
            ChannelEPG(id: 9, number: 100, name: "X", programs: [entry("xa", 90, 130), entry("xc", 115, 150), entry("xd", 150, 200)], external: true),
        ])
        for windows in [[before, after], [after, before]] {
            var grid = ChannelGuideGrid(windows[0])
            grid.merge(windows[1])
            XCTAssertEqual(grid.rows[0].programs.map(\.key), ["xa", "xc", "xd"])
            XCTAssertEqual(grid.rows[0].programs.map(\.start), [t(90), t(115), t(150)])
            XCTAssertEqual(grid.rows[0].programs.map(\.end), [t(130), t(150), t(200)])
        }
        // As the server sends them: no `itemId` at all.
        let decoded = try JSONDecoder().decode(ChannelProgram.self, from: Data(
            #"{"id":"xhttp://a-90000","kind":"external","title":"A","start":"2026-11-01T10:00:00Z","end":"2026-11-01T11:00:00Z"}"#.utf8
        ))
        XCTAssertEqual(decoded.itemId, 0)
        var other = decoded
        other.id = "xhttp://a-93000"
        other.start = decoded.start.addingTimeInterval(1800)
        other.end = decoded.end.addingTimeInterval(1800)
        let window = ChannelEPGWindow(from: decoded.start.addingTimeInterval(2400), to: decoded.end.addingTimeInterval(7200), channels: [])
        XCTAssertEqual(ChannelGuideGrid.joined(other, with: [decoded], in: window), other)
    }

    /// A film of one file, 60–140, with the windows' edge at 120; the schedule is rebuilt
    /// between the two pages and the film now runs 100–180 (entries after the rebuilt
    /// point keep their numbers, so its id is the same). It is not 60–180.
    func testAProgrammeMovedByARebuiltScheduleIsNotStretched() {
        func film(_ start: TimeInterval, _ end: TimeInterval) -> ChannelProgram {
            ChannelProgram(id: "1-2", itemId: 7, title: "Film", start: t(start), end: t(end))
        }
        var grid = ChannelGuideGrid(ChannelEPGWindow(from: t(0), to: t(120), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [program("1-1", 0, 60), film(60, 140)]),
        ]))
        grid.merge(ChannelEPGWindow(from: t(120), to: t(240), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [film(100, 180), program("1-3", 180, 240)]),
        ]))
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["1-1", "1-2", "1-3"])
        XCTAssertEqual(grid.rows[0].programs[1].start, t(100))
        XCTAssertEqual(grid.rows[0].programs[1].end, t(180))

        // Moved earlier, seen scrolling back: the same.
        grid = ChannelGuideGrid(ChannelEPGWindow(from: t(120), to: t(240), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [film(100, 180), program("1-3", 180, 240)]),
        ]))
        grid.merge(ChannelEPGWindow(from: t(0), to: t(120), channels: [
            ChannelEPG(id: 1, number: 1, name: "A", programs: [program("1-1", 0, 60), film(60, 140)]),
        ]))
        XCTAssertEqual(grid.rows[0].programs[1].start, t(60))
        XCTAssertEqual(grid.rows[0].programs[1].end, t(140))
    }

    private func show(_ id: String, item: Int, _ start: TimeInterval, _ end: TimeInterval) -> ChannelProgram {
        ChannelProgram(id: id, itemId: item, title: "Item \(item)", start: t(start), end: t(end))
    }

    private func page(_ from: TimeInterval, _ to: TimeInterval, _ programs: [ChannelProgram]) -> ChannelEPGWindow {
        ChannelEPGWindow(from: t(from), to: t(to), channels: [ChannelEPG(id: 1, number: 1, name: "A", programs: programs)])
    }

    /// One key per programme of a row, and no two programmes over the same time.
    private func assertConsistent(_ grid: ChannelGuideGrid, file: StaticString = #filePath, line: UInt = #line) {
        let programs = grid.rows[0].programs
        XCTAssertEqual(Set(programs.map(\.key)).count, programs.count, "keys repeat: \(programs.map(\.key))", file: file, line: line)
        for (a, b) in zip(programs, programs.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "\(a.key) and \(b.key) overlap", file: file, line: line)
        }
    }

    /// The server gives programme ids again after a rebuild (entries from the rebuilt
    /// point on are deleted and numbered anew): between two pages "1-2" became another
    /// programme. The newer page's copy stands, whichever page it is.
    func testAScheduleRebuiltBetweenTwoPages() {
        let first = page(0, 120, [show("1-1", item: 1, 0, 60), show("1-2", item: 2, 60, 140)])
        let rebuilt = page(120, 240, [show("1-2", item: 3, 110, 170), show("1-3", item: 4, 170, 240)])
        var grid = ChannelGuideGrid(first)
        grid.merge(rebuilt)
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["1-1", "1-2", "1-3"])
        XCTAssertEqual(grid.rows[0].programs.map(\.itemId), [1, 3, 4])
        XCTAssertEqual(grid.rows[0].programs[1].start, t(110))
        assertConsistent(grid)

        // The same programme under the same id with a new end: the newer end.
        grid = ChannelGuideGrid(page(0, 240, [show("1-1", item: 1, 0, 60), show("1-2", item: 2, 60, 200)]))
        grid.merge(page(0, 240, [show("1-1", item: 1, 0, 60), show("1-2", item: 2, 60, 150), show("1-3", item: 5, 150, 240)]))
        XCTAssertEqual(grid.rows[0].programs.map(\.end), [t(60), t(150), t(240)])
        assertConsistent(grid)

        // Known programmes inside the newer page's span that it no longer lists are gone,
        // those outside it stay.
        grid = ChannelGuideGrid(page(0, 240, [show("1-1", item: 1, 0, 60), show("1-2", item: 2, 60, 130), show("1-3", item: 3, 130, 150), show("1-4", item: 4, 150, 240)]))
        grid.merge(page(120, 240, [show("1-2", item: 2, 60, 200), show("1-3", item: 6, 200, 240)]))
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["1-1", "1-2", "1-3"])
        XCTAssertEqual(grid.rows[0].programs.map(\.itemId), [1, 2, 6])
        assertConsistent(grid)
    }

    /// The known half of a film has a key the newer page gives to another programme, and
    /// the film itself comes under a new one: joining would put two blocks under one key
    /// (focus moving right from the second would jump back to the first).
    func testAJoinNeverGivesTwoProgrammesOneKey() {
        var grid = ChannelGuideGrid(page(0, 120, [show("1-1", item: 1, 0, 60), show("1-2", item: 7, 60, 140)]))
        grid.merge(page(120, 240, [show("1-2", item: 9, 90, 110), show("1-3", item: 7, 110, 200), show("1-4", item: 4, 200, 240)]))
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["1-1", "1-2", "1-3", "1-4"])
        XCTAssertEqual(grid.rows[0].programs.map(\.itemId), [1, 9, 7, 4])
        XCTAssertEqual(grid.rows[0].programs[2].start, t(110))
        assertConsistent(grid)

        // A page that repeats a key itself keeps one programme under it.
        grid = ChannelGuideGrid(page(0, 120, [show("1-1", item: 1, 0, 60), show("1-1", item: 2, 60, 120)]))
        XCTAssertEqual(grid.rows[0].programs.map(\.itemId), [2])
        grid.merge(page(0, 120, [show("1-1", item: 1, 0, 60), show("1-1", item: 2, 60, 120)]))
        assertConsistent(grid)
    }

    private func entry(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> ChannelProgram {
        ChannelProgram(id: id, itemId: 0, kind: "external", title: id, start: t(start), end: t(end))
    }

    private func externalPage(_ from: TimeInterval, _ to: TimeInterval, _ programs: [ChannelProgram]) -> ChannelEPGWindow {
        ChannelEPGWindow(from: t(from), to: t(to), channels: [ChannelEPG(id: 9, number: 100, name: "X", programs: programs, external: true)])
    }

    /// A sloppy external guide: O 10:00–11:59 and A 11:30–12:10 overlap. The page
    /// 06:00–12:00 lists both, the page 12:00–18:00 only A (O is over before it). O is
    /// outside the newer page's span and stays, in either order of the pages.
    func testAnExternalProgrammeOutsideThePageStaysThoughItOverlapsOneOfThePages() {
        let h: TimeInterval = 3600
        let o = entry("x1-36000", 10 * h, 12 * h - 60)
        let a = entry("x1-41400", 11.5 * h, 12 * h + 600)
        let b = entry("x1-43800", 12 * h + 600, 13 * h)
        let morning = externalPage(6 * h, 12 * h, [o, a])
        let afternoon = externalPage(12 * h, 18 * h, [a, b])
        for pages in [[morning, afternoon], [afternoon, morning], [morning, afternoon, afternoon], [afternoon, morning, afternoon]] {
            var grid = ChannelGuideGrid(pages[0])
            for next in pages.dropFirst() { grid.merge(next) }
            XCTAssertEqual(grid.rows[0].programs, [o, a, b])
        }
        // An entry that reaches into the newer page's span and is not in it is gone (the
        // page lists all that do), and so is one that starts inside it.
        var grid = ChannelGuideGrid(externalPage(6 * h, 12 * h, [o, entry("x1-old", 11.5 * h, 12.5 * h)]))
        grid.merge(externalPage(12 * h, 18 * h, [entry("x1-new", 11.75 * h, 13 * h)]))
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["x1-36000", "x1-new"])
        // A library programme outside the span that lies over one of the page's is stale.
        grid = ChannelGuideGrid(page(0, 120, [show("1-1", item: 1, 0, 60), show("1-2", item: 2, 60, 110)]))
        grid.merge(page(120, 240, [show("1-7", item: 3, 100, 170), show("1-8", item: 4, 170, 240)]))
        XCTAssertEqual(grid.rows[0].programs.map(\.key), ["1-1", "1-7", "1-8"])
        assertConsistent(grid)
    }

    /// The same film three times back to back, the pages' edge inside the second
    /// showing: three programmes, each with its own times, in either order of pages and
    /// after either page again.
    func testTheSameFilmThreeTimesInARowStaysThreeProgrammes() {
        let shows = [show("1-1", item: 7, 0, 100), show("1-2", item: 7, 100, 200), show("1-3", item: 7, 200, 300)]
        let first = page(0, 150, Array(shows[0...1]))
        let second = page(150, 300, Array(shows[1...2]))
        for pages in [[first, second], [second, first], [first, second, first, second], [second, first, second]] {
            var grid = ChannelGuideGrid(pages[0])
            for next in pages.dropFirst() { grid.merge(next) }
            XCTAssertEqual(grid.rows[0].programs, shows)
            assertConsistent(grid)
        }
        // The edge exactly between two showings.
        var grid = ChannelGuideGrid(page(0, 100, [shows[0]]))
        grid.merge(page(100, 200, [shows[1]]))
        grid.merge(page(200, 300, [shows[2]]))
        grid.merge(page(100, 200, [shows[1]]))
        XCTAssertEqual(grid.rows[0].programs, shows)
    }

    func testCursorLandsOnTheProgrammeOnAirElseTheNearest() {
        let row = ChannelEPG(id: 1, number: 1, name: "A", programs: [program("a", 100, 200), program("b", 300, 400)])
        XCTAssertEqual(row.program(near: t(150))?.id, "a")
        XCTAssertEqual(row.program(near: t(250))?.id, "b", "a gap: the next programme")
        XCTAssertEqual(row.program(near: t(50))?.id, "a")
        XCTAssertEqual(row.program(near: t(500))?.id, "b", "after the last: the last")
        XCTAssertNil(ChannelEPG(id: 2, number: 2, name: "B").program(near: t(0)))
    }

    func testScaleFitsTheSchedule() {
        // Films: the TV guide's usual half hour ≈ 320 pt, ticks every 30 minutes.
        let films = GuideScale.fitting(typicalLength: 100 * 60)
        XCTAssertEqual(films.width(30 * 60), 320, accuracy: 0.01)
        XCTAssertEqual(films.tickMinutes, 30)
        XCTAssertEqual(GuideScale.fitting(typicalLength: nil), films)
        // Seven-minute programmes are zoomed in to be readable.
        let short = GuideScale.fitting(typicalLength: 7 * 60)
        XCTAssertEqual(short.width(7 * 60), GuideScale.typicalWidth, accuracy: 0.01)
        XCTAssertEqual(short.tickMinutes, 5)
        // Never closer than the maximum.
        XCTAssertEqual(GuideScale.fitting(typicalLength: 30).pointsPerMinute, GuideScale.maxPointsPerMinute)
        XCTAssertEqual(films.interval(films.width(1234)), 1234, accuracy: 0.001)
        let tick = films.tick(atOrBefore: t(3600 * 5 + 29 * 60 + 59))
        XCTAssertEqual(tick, t(3600 * 5))
        XCTAssertEqual(ChannelGuideGrid.typicalLength(of: [ChannelEPG(id: 1, number: 1, name: "", programs: [program("a", 0, 10), program("b", 10, 40), program("c", 40, 100)])]), 30)
    }

    func testTicksBlocksAndNowShareOneAxis() {
        let scale = GuideScale.fitting(typicalLength: 7 * 60)
        let origin = t(85_500)  // a tick
        XCTAssertEqual(scale.tick(atOrBefore: origin), origin)
        let tick = TimeInterval(scale.tickMinutes * 60)
        // A tick, a programme starting on it and "now" at the same instant are at one x.
        let start = origin.addingTimeInterval(2 * tick)
        XCTAssertEqual(scale.x(start, from: origin), 2 * scale.width(tick), accuracy: 1e-9)
        XCTAssertEqual(scale.x(origin, from: origin), 0)
        // 23:47 on an axis from 23:45 at 60 pt/min is 120 pt, not 174.
        let fine = GuideScale(pointsPerMinute: 60, tickMinutes: 5)
        XCTAssertEqual(fine.x(t(85_500 + 120), from: origin), 120, accuracy: 1e-9)
        XCTAssertEqual(fine.date(atX: 120, from: origin), t(85_500 + 120))
        // A start with seconds (23:47:54.9) sits 0.9 pt short of the 23:48 tick, not at 23:47.
        let withSeconds = t(85_500 + 174.9)
        XCTAssertEqual(fine.x(withSeconds, from: origin), 174.9, accuracy: 1e-4)
        XCTAssertEqual(fine.x(t(85_500 + 180), from: origin) - fine.x(withSeconds, from: origin), 5.1, accuracy: 1e-4)
        // Before the origin: negative.
        XCTAssertEqual(fine.x(t(85_500 - 60), from: origin), -60, accuracy: 1e-9)
    }

    // MARK: Live audio and subtitles

    private let ru = LiveTrack(slot: "ru", name: "Русский", label: "Русский — LostFilm", lang: "ru")
    private let ru2 = LiveTrack(slot: "ru2", name: "Русский 2", label: "Русский — Кубик в кубе", lang: "ru")
    private let en = LiveTrack(slot: "en", name: "English", label: "English", lang: "en")
    private let orig = LiveTrack(slot: "orig", name: "Оригинал", label: "Оригинал (fr)", lang: "fr")
    private let subRu = LiveTrack(slot: "ru", name: "Русские", label: "Русские", lang: "ru")
    private let subEn = LiveTrack(slot: "en", name: "English", label: "English", lang: "en")

    func testAudioDefaultsToTheProfilesFirstLanguageThatIsThere() {
        let none = LiveTrackSelection()
        XCTAssertEqual(none.audio(in: [ru, ru2, en], prefs: PlaybackPrefs(audioLangs: ["en", "ru"]), device: []), en)
        XCTAssertEqual(none.audio(in: [ru, ru2, en], prefs: PlaybackPrefs(audioLangs: ["ru", "en"]), device: []), ru)
        XCTAssertEqual(none.audio(in: [ru, orig], prefs: PlaybackPrefs(audioLangs: ["de"]), device: []), orig, "the original, else the first")
        XCTAssertEqual(none.audio(in: [ru2, ru], prefs: PlaybackPrefs(audioLangs: ["de"]), device: []), ru2)
        XCTAssertNil(none.audio(in: [], prefs: PlaybackPrefs(audioLangs: ["en"]), device: []))
        XCTAssertEqual(none.audio(in: [orig, en], prefs: PlaybackPrefs(audioLangs: ["fr", "en"]), device: []), orig)
    }

    /// Round 6: the device's system language comes before the profile's.
    func testAudioDefaultsToTheDevicesLanguageFirst() {
        let none = LiveTrackSelection()
        XCTAssertEqual(none.audio(in: [ru, ru2, en], prefs: PlaybackPrefs(audioLangs: ["ru"]), device: ["en-GB"]), en)
        XCTAssertEqual(none.audio(in: [ru, ru2, en], prefs: PlaybackPrefs(audioLangs: ["en"]), device: ["ru-RU", "en"]), ru)
        XCTAssertEqual(none.audio(in: [ru, en], prefs: PlaybackPrefs(audioLangs: ["en"]), device: ["de"]), en, "then the profile's")
    }

    func testTheViewersPickSticksByNameThenLanguage() {
        let picked = LiveTrackSelection(audio: .init(ru2), subtitle: .some(.init(subEn)))
        XCTAssertEqual(picked.audio(in: [ru, ru2, en], prefs: PlaybackPrefs(audioLangs: ["en"])), ru2)
        // The next programme has no «Русский 2»: the first Russian one.
        XCTAssertEqual(picked.audio(in: [en, ru], prefs: PlaybackPrefs(audioLangs: ["en"])), ru)
        XCTAssertEqual(picked.subtitle(in: [subRu, subEn], audio: ru, prefs: PlaybackPrefs()), subEn)
        XCTAssertNil(picked.subtitle(in: [subRu], audio: ru, prefs: PlaybackPrefs()), "no English: the defaults (off)")
        let off = LiveTrackSelection(subtitle: .some(nil))
        XCTAssertNil(off.subtitle(in: [subRu, subEn], audio: ru, prefs: PlaybackPrefs(subMode: "always", subLangs: ["ru"])))
    }

    func testSubtitleDefaultsFollowTheMode() {
        let none = LiveTrackSelection()
        let subs = [subRu, subEn]
        XCTAssertNil(none.subtitle(in: subs, audio: ru, prefs: PlaybackPrefs(audioLangs: ["ru"], subMode: "off", subLangs: ["ru"])))
        XCTAssertEqual(none.subtitle(in: subs, audio: ru, prefs: PlaybackPrefs(audioLangs: ["ru"], subMode: "always", subLangs: ["en", "ru"])), subEn)
        XCTAssertEqual(none.subtitle(in: subs, audio: ru, prefs: PlaybackPrefs(audioLangs: ["ru"], subMode: "always", subLangs: [])), subRu, "subLangs empty: audioLangs")
        // Foreign: only when the audio's language is not one of the profile's.
        let foreign = PlaybackPrefs(audioLangs: ["ru"], subMode: "foreign", subLangs: ["ru"])
        XCTAssertNil(none.subtitle(in: subs, audio: ru, prefs: foreign))
        XCTAssertEqual(none.subtitle(in: subs, audio: orig, prefs: foreign), subRu)
        XCTAssertNil(none.subtitle(in: subs, audio: nil, prefs: foreign), "no voice known")
        XCTAssertNil(none.subtitle(in: [], audio: orig, prefs: foreign), "none to show")
    }

    /// Round 5: eight voices with arbitrary names, a master read by the app, AVFoundation's
    /// options renamed by language.
    func testRenditionsOfAnyNameAndCount() {
        let names = ["Дубляж", "LostFilm", "Кураж-Бамбей", "LostFilm (очищено)", "Оригинал (English)", "Français", "Deutsch", "Español"]
        let langs = ["ru", "ru", "ru", "ru", "en", "fr", "de", "es"]
        var master = "#EXTM3U\n"
        for (i, n) in names.enumerated() {
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(n)\",LANGUAGE=\"\(langs[i])\",DEFAULT=\(i == 0 ? "YES" : "NO"),URI=\"audio-\(i).m3u8\"\n"
        }
        master += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"sub\",NAME=\"Русские, полные\",LANGUAGE=\"ru\",URI=\"subs-0.m3u8\"\n"
        master += "#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"aud\"\nvideo.m3u8\n"
        let r = LiveRenditions(master: Data(master.utf8))
        XCTAssertEqual(r.audio.map(\.name), names)
        XCTAssertEqual(r.subtitles.map(\.name), ["Русские, полные"], "a quoted comma")
        XCTAssertTrue(r.audio[0].isDefault)
        let renamed: [(name: String, lang: String)] = langs.map { ($0 == "ru" ? "Русский" : "Другой", $0) }
        XCTAssertEqual(LiveRenditions.option(named: "LostFilm (очищено)", lang: "ru", options: renamed, renditions: r.audio), 3)
        XCTAssertEqual(LiveRenditions.option(named: "Deutsch", lang: "de", options: renamed, renditions: r.audio), 6)
        XCTAssertEqual(LiveRenditions.name(ofOption: 2, options: renamed, renditions: r.audio), "Кураж-Бамбей")
        // Fewer options than renditions: per language, in order.
        let fewer = Array(renamed.prefix(3)) + [renamed[6]]
        XCTAssertEqual(LiveRenditions.option(named: "Deutsch", lang: "de", options: fewer, renditions: r.audio), 3)
        XCTAssertEqual(LiveRenditions.option(named: "LostFilm", lang: "ru", options: fewer, renditions: r.audio), 1)
        // A name the run does not carry: the first of its language.
        XCTAssertEqual(LiveRenditions.option(named: "Многоголосый", lang: "ru", options: renamed, renditions: r.audio), 0)
        // Titles kept by the asset: by name.
        let titled = names.reversed().map { ($0, "") }
        XCTAssertEqual(LiveRenditions.option(named: "Дубляж", lang: "ru", options: titled, renditions: r.audio), 7)
    }

    func testVoiceAndLanguage() {
        XCTAssertEqual(LiveTrack(name: "LostFilm", label: "Русский — LostFilm", lang: "ru").voiceAndLanguage.voice, "LostFilm")
        XCTAssertEqual(LiveTrack(name: "LostFilm", label: "Русский — LostFilm", lang: "ru").voiceAndLanguage.language, "Русский")
        XCTAssertNil(LiveTrack(name: "English", label: "English", lang: "en").voiceAndLanguage.language)
        XCTAssertEqual(LiveTrack(name: "x", lang: "").voiceAndLanguage.voice, "x")
    }

    func testTracksAndLogosDecode() throws {
        let json = Data(#"{"id":3,"number":3,"name":"Кино","logoUrl":"/api/channels/3/logo.png?v=1","now":{"itemId":1,"title":"Много голосов","start":"2026-11-12T10:00:00Z","end":"2026-11-12T12:00:00Z","audio":[{"name":"Дубляж","label":"Русский — Дубляж","lang":"ru"},{"slot":"x","name":"LostFilm","lang":"ru"}]}}"#.utf8)
        let channel = try JSONDecoder().decode(Channel.self, from: json)
        XCTAssertEqual(channel.logoUrl, "/api/channels/3/logo.png?v=1")
        XCTAssertEqual(channel.now?.audio?.map(\.id), ["Дубляж", "LostFilm"])
        XCTAssertEqual(channel.now?.audio?.first?.slot, "Дубляж", "no slot: the name")
        XCTAssertEqual(channel.now?.audio?.last?.title, "LostFilm")
        let bare = try JSONDecoder().decode(Channel.self, from: Data(#"{"id":4,"number":4,"name":"Б"}"#.utf8))
        XCTAssertEqual(bare.logoUrl, "")
        var grid = ChannelGuideGrid(ChannelEPGWindow(from: Date(), to: Date(), channels: [ChannelEPG(id: 3, number: 3, name: "Кино"), ChannelEPG(id: 4, number: 4, name: "Б")]))
        grid.applyLogos(from: [channel, bare])
        XCTAssertEqual(grid.rows.map(\.logoUrl), ["/api/channels/3/logo.png?v=1", ""])
        XCTAssertEqual(grid.rows[0].channel.logoUrl, channel.logoUrl)
    }

    // MARK: TV is TV

    /// Tunes in, zaps, refreshes the list and the guide, stars and unstars a channel and
    /// reads the profile's defaults through `ChannelService`, the only way the app talks to
    /// the server about channels: nothing but the favourite and the last channel is written,
    /// and nothing touches progress, playback, resume, watched marks, tracks or scrobbles.
    func testChannelsLeaveNoHistory() async throws {
        let transport = MockTransport { request in
            switch request.url?.path ?? "" {
            case "/api/channels": return .json(#"{"channels":[{"id":1,"number":1},{"id":2,"number":2}],"lastChannel":1}"#)
            case "/api/channels/epg": return .json(#"{"channels":[]}"#)
            case "/api/channels/1/guide", "/api/channels/2/guide": return .json(#"{"channel":{"id":1},"programs":[]}"#)
            case "/api/me/playback-prefs": return .json(#"{"audioLangs":["ru"],"subMode":"off"}"#)
            case let path where path.hasPrefix("/api/channels/live/"): return MockTransport.Reply(status: 200, body: Data("#EXTM3U\n".utf8), headers: [:])
            default: return .noContent
            }
        }
        let service = ChannelService(client: APIClient(baseURL: URL(string: "http://tv.test:8420")!, token: "t", transport: transport))
        _ = try await service.list()
        _ = try await service.playbackPrefs()
        _ = try await service.epg(from: nil)
        _ = try await service.tuneIn(channelId: 1, mediaKey: "k")
        _ = try await service.guide(channelId: 1)
        _ = try await service.tuneIn(channelId: 2, mediaKey: "k")
        _ = try await service.guide(channelId: 2)
        try await service.setFavorite(channelId: 2, true)
        try await service.setFavorite(channelId: 2, false)
        _ = try await service.list()

        let requests = transport.requests.map { ($0.httpMethod ?? "GET", $0.url?.path ?? "") }
        let writes = requests.filter { $0.0 != "GET" }
        XCTAssertEqual(writes.map { "\($0.0) \($0.1)" }, [
            "PUT /api/channels/last", "PUT /api/channels/last", "PUT /api/channels/2/favorite", "DELETE /api/channels/2/favorite",
        ])
        for (method, path) in requests {
            XCTAssertTrue(method == "GET" || ChannelService.isAllowedWrite(method: method, path: path), "\(method) \(path)")
            for forbidden in ["/api/progress", "/api/play", "/api/hls", "/api/items", "/api/scrobble", "/api/watched", "/api/history"] {
                XCTAssertFalse(path.hasPrefix(forbidden), "\(method) \(path)")
            }
        }
        XCTAssertFalse(ChannelService.isAllowedWrite(method: "PUT", path: "/api/items/3/track-prefs"))
        XCTAssertFalse(ChannelService.isAllowedWrite(method: "PUT", path: "/api/progress/3"))
        XCTAssertFalse(ChannelService.isAllowedWrite(method: "POST", path: "/api/channels/last"))
    }

    func testALastChannelThatFailsToSaveStillPlays() async throws {
        let transport = MockTransport { request in
            request.url?.path == "/api/channels/last" ? .json(#"{"error":"nope"}"#, status: 500) : MockTransport.Reply(status: 200, body: Data("#EXTM3U\n".utf8), headers: [:])
        }
        let service = ChannelService(client: APIClient(baseURL: URL(string: "http://tv.test:8420")!, token: "t", transport: transport))
        let url = try await service.tuneIn(channelId: 4, mediaKey: nil)
        XCTAssertEqual(url.path, "/api/channels/live/4/index.m3u8")
    }

    // MARK: External voice-overs (the film player)

    func testExternalAndCleanedTracksDecodeAndOrder() throws {
        let json = #"""
        [{"index":1,"codec":"aac","lang":"rus","title":"Русский — LostFilm","channels":2,"default":true},
         {"index":3,"codec":"aac","lang":"eng","title":"English","channels":2},
         {"index":2000,"codec":"aac","lang":"ru","title":"Кураж-Бамбей","channels":2,"external":true,"src":"31852dba","studio":"Кураж-Бамбей"},
         {"index":2001,"codec":"aac","lang":"ru","title":"LostFilm","channels":2,"external":true,"src":"aa11","studio":"LostFilm","kind":"cleaned","method":"subtraction","cleanedFrom":1}]
        """#
        let tracks = try JSONDecoder().decode([AudioTrack].self, from: Data(json.utf8))
        XCTAssertFalse(tracks[0].external)
        XCTAssertEqual(tracks[2].src, "31852dba")
        XCTAssertEqual(tracks[2].studio, "Кураж-Бамбей")
        XCTAssertTrue(tracks[3].isCleaned)
        XCTAssertEqual(tracks[3].cleanedFrom, 1)
        XCTAssertEqual(tracks[3].method, "subtraction")
        // The cleaned voice-over right under the track it was made from.
        XCTAssertEqual(AudioTrack.menuOrder(tracks).map(\.index), [1, 2001, 3, 2000])
    }

    func testAnExternalTrackIsAskedForByItsSource() throws {
        let request = PlayRequest(caps: .appleTV(), audioIndex: 2000, audioSrc: "31852dba")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(body["audioIndex"] as? Int, 2000)
        XCTAssertEqual(body["audioSrc"] as? String, "31852dba")
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlayRequest(caps: .appleTV(), audioIndex: 2))) as? [String: Any])
        XCTAssertNil(plain["audioSrc"])
    }
}

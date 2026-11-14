import XCTest
@testable import AntresolKit

final class CleanedSwitchTests: XCTestCase {
    private let audio = [
        AudioTrack(index: 1, codec: "eac3", lang: "eng", title: "", channels: 6),
        AudioTrack(index: 2, codec: "eac3", lang: "rus", title: "LostFilm", channels: 6),
        AudioTrack(index: 2000, codec: "eac3", lang: "rus", title: "LostFilm", channels: 6, kind: "cleaned", cleanedFrom: 2),
    ]

    func testOffTheSwitchTurnsToTheCleanedVersion() {
        let s = CleanedSwitch(audio: audio, audioIndex: 2)
        XCTAssertEqual(s.rows.map(\.track.index), [1, 2])
        XCTAssertEqual(s.rows.map(\.checked), [false, true])
        XCTAssertEqual(s.toggle?.on, false)
        XCTAssertEqual(s.toggle?.target, 2000)
    }

    func testOnTheVoiceStaysChosenAndTheSwitchTurnsBack() {
        let s = CleanedSwitch(audio: audio, audioIndex: 2000)
        XCTAssertEqual(s.rows.map(\.checked), [false, true])
        XCTAssertEqual(s.rows.map(\.plays), [1, 2000])
        XCTAssertEqual(s.toggle?.on, true)
        XCTAssertEqual(s.toggle?.target, 2)
    }

    func testNoSwitchOnTheOriginal() {
        XCTAssertNil(CleanedSwitch(audio: audio, audioIndex: 1).toggle)
    }

    func testACleanedTrackWithoutItsSourceStaysARow() {
        let lone = [audio[0], AudioTrack(index: 2000, codec: "eac3", lang: "rus", title: "LostFilm", channels: 6, kind: "cleaned", cleanedFrom: 9)]
        XCTAssertEqual(CleanedSwitch(audio: lone, audioIndex: 1).rows.map(\.track.index), [1, 2000])
    }
}

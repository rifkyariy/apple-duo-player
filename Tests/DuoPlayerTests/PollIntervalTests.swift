import XCTest
@testable import DuoPlayer

final class PollIntervalTests: XCTestCase {
    func testPollInterval() {
        XCTAssertEqual(Player.pollInterval(hasTrack: false, playing: false, remaining: 0), 10)
        XCTAssertEqual(Player.pollInterval(hasTrack: true, playing: false, remaining: 100), 30)
        XCTAssertEqual(Player.pollInterval(hasTrack: true, playing: true, remaining: 100), 10)   // capped
        XCTAssertEqual(Player.pollInterval(hasTrack: true, playing: true, remaining: 3), 3.8)    // right after the song ends
        XCTAssertEqual(Player.pollInterval(hasTrack: true, playing: true, remaining: -5), 1)     // overran: floor, never hammer
    }
}

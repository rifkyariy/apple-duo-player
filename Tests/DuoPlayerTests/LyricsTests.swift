import XCTest
@testable import DuoPlayer

final class LyricsTests: XCTestCase {
    func testParseAndIndex() {
        let lines = Lyrics.parse("""
        [ar: Someone]
        [00:12.50] second
        [00:01.00] first
        [01:02.00]
        not a lyric
        """)
        XCTAssertEqual(lines.map(\.time), [1, 12.5, 62])
        XCTAssertEqual(lines.map(\.text), ["first", "second", "♪"])
        XCTAssertNil(Lyrics.index(lines, at: 0.5))
        XCTAssertEqual(Lyrics.index(lines, at: 12.5), 1)
        XCTAssertEqual(Lyrics.index(lines, at: 999), 2)
    }
}

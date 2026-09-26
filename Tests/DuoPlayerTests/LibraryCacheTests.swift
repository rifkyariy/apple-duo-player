import XCTest
@testable import DuoPlayer

final class LibraryCacheTests: XCTestCase {
    func testSaveLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "duo-\(UUID())/library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let me = try JSONDecoder().decode(SPMe.self, from: Data(#"{"display_name":"Ann","images":[{"url":"https://x/a.jpg"}],"followers":{"total":3}}"#.utf8))
        let a = Album(uri: "spotify:album:1", name: "A", art: URL(string: "https://x/1.jpg"))
        LibraryCache(albums: [a], playlists: [], topArtists: [a], me: me, savedAt: Date(timeIntervalSince1970: 100)).save(to: url)

        let c = try XCTUnwrap(LibraryCache.load(from: url))
        XCTAssertEqual(c.albums.map(\.uri), ["spotify:album:1"])
        XCTAssertEqual(c.topArtists.first?.art, a.art)
        XCTAssertEqual(c.me?.display_name, "Ann")
        XCTAssertEqual(c.me?.followers?.total, 3)
        XCTAssertEqual(c.savedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(LibraryCache.load(from: url.appending(path: "missing")))
    }
}

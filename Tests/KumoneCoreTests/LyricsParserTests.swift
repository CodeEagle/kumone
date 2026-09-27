import Testing
@testable import KumoneCore

@Suite("Lyrics parsing and positioning")
struct LyricsParserTests {
    @Test func yrcSortsLinesByStartTimeAndPreservesIDs() {
        let lines = LyricsParser.parseYRC("""
            [3000,1000](3000,1000,0)Third
            [1000,1000](1000,1000,0)First
            [2000,1000](2000,1000,0)Second
            """)

        #expect(lines.map(\.time) == [1, 2, 3])
        #expect(lines.map(\.text) == ["First", "Second", "Third"])
        #expect(lines.map(\.id) == [1, 2, 0])
        #expect(Set(lines.map(\.id)).count == lines.count)
        #expect(lines.map { $0.words?.first?.start } == [1, 2, 3])
    }

    @Test func yrcPreservesInputOrderForDuplicateTimestamps() {
        let lines = LyricsParser.parseYRC("""
            [2000,1000](2000,1000,0)First duplicate
            [1000,1000](1000,1000,0)Earlier
            [2000,1000](2000,1000,0)Second duplicate
            [3000,1000](3000,1000,0)Later
            [2000,1000](2000,1000,0)Third duplicate
            """)

        #expect(lines.map(\.time) == [1, 2, 2, 2, 3])
        #expect(lines.map(\.text) == [
            "Earlier", "First duplicate", "Second duplicate", "Third duplicate", "Later",
        ])
        #expect(lines.map(\.id) == [1, 0, 2, 4, 3])

        var lyrics = ParsedLyrics()
        lyrics.lines = lines
        #expect(lyrics.activeIndex(at: 2) == 3)
    }

    @Test func activeIndexUsesSortedYRCAndHandlesPlaybackBoundaries() {
        var lyrics = ParsedLyrics()
        lyrics.lines = LyricsParser.parseYRC("""
            [3000,1000](3000,1000,0)Third
            [1000,1000](1000,1000,0)First
            [2000,1000](2000,1000,0)Second
            """)

        #expect(lyrics.activeIndex(at: 0.5) == nil)
        #expect(lyrics.activeIndex(at: 1) == 0)
        #expect(lyrics.activeIndex(at: 1.5) == 0)
        #expect(lyrics.activeIndex(at: 2) == 1)
        #expect(lyrics.activeIndex(at: 2.5) == 1)
        #expect(lyrics.activeIndex(at: 3) == 2)
        #expect(lyrics.activeIndex(at: 10) == 2)
    }

    @Test func activeIndexIsNilForEmptyLyrics() {
        #expect(ParsedLyrics().activeIndex(at: 0) == nil)
    }
}

import Testing
@testable import LintelCore

@Suite struct FieldSuggestions {
    @Test func suggestionsReadTitleSubtitleAndValue() throws {
        let reply = try JSONValue.parse(#"[{ "title": "Paris", "subtitle": "Europe · 09:05", "value": "Europe/Paris" }]"#)
        #expect(FieldSuggestion.list(from: reply) == [FieldSuggestion(title: "Paris", subtitle: "Europe · 09:05", value: "Europe/Paris")])
    }

    @Test func aPlainStringIsBothTitleAndValue() throws {
        #expect(FieldSuggestion.list(from: try JSONValue.parse(#"["Paris"]"#)) == [FieldSuggestion(title: "Paris", subtitle: nil, value: "Paris")])
    }

    @Test func aSuggestionWithoutAValueSubmitsItsTitle() throws {
        #expect(FieldSuggestion.list(from: try JSONValue.parse(#"[{ "title": "Paris" }]"#)).first?.value == "Paris")
    }

    @Test func untitledEntriesAndAnythingButAListAreIgnored() throws {
        #expect(FieldSuggestion.list(from: try JSONValue.parse(#"[{ "value": "x" }, 3, null, ""]"#)).isEmpty)
        #expect(FieldSuggestion.list(from: try JSONValue.parse(#"{ "title": "Paris" }"#)).isEmpty)
        #expect(FieldSuggestion.list(from: .null).isEmpty)
    }

    @Test func atMostSixSuggestionsAreShown() throws {
        let reply = JSONValue.array((1...10).map { .string("City \($0)") })
        #expect(FieldSuggestion.list(from: reply).map(\.title) == (1...6).map { "City \($0)" })
    }
}

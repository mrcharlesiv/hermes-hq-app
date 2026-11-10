// Mac UX stress test #59: ids Hermes sends read as words on screen; the values sent back stay the ids.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct DisplayNameTests {
    @Test func slugsReadAsWords() {
        #expect(DisplayName.title("web-search") == "Web Search")
        #expect(DisplayName.title("github-pr") == "GitHub PR")
        #expect(DisplayName.title("pdf-reader") == "PDF Reader")
        #expect(DisplayName.title("hermes-hq-browser") == "Hermes HQ Browser")
        #expect(DisplayName.title("server_030") == "Server 030")
        #expect(DisplayName.title("weather") == "Weather")
    }

    /// Round 2: brand spellings in slugs and in a choice's label.
    @Test func brandsKeepTheirCasing() {
        #expect(DisplayName.title("duckduckgo") == "DuckDuckGo")
        #expect(DisplayName.title("openai-tts") == "OpenAI TTS")
        #expect(ConfigText.pretty("duckduckgo") == "DuckDuckGo")
        #expect(ConfigText.pretty("github_search") == "GitHub Search")
        #expect(ConfigRenderer.optionLabel(key: "timezone", "America/New_York") == "New York (America)")
        #expect(AuxiliaryAssignment.title("mcp") == "Connectors")
        #expect(ConfigCopy.labels["approvals.mcp_reload_confirm"] == "Ask Before Reloading Connectors")
        #expect(ConfigCopy.descriptions["toolsets"]?.contains("toolsets") == false)
    }

    @Test func ownSpellingIsKept() {
        #expect(DisplayName.title("Google Calendar") == "Google Calendar")
        #expect(DisplayName.title("myServer") == "myServer")
        #expect(DisplayName.title("") == "")
    }

    @Test func contextWindowZeroIsAutomatic() {
        var field = ConfigFieldModel(key: "model_context_length", label: "", description: "", control: .number, value: .number(0), defaultValue: nil)
        #expect(ConfigRenderer.summary(field) == "Automatic")
        field.value = .number(200_000)
        #expect(ConfigRenderer.summary(field) == "200000")
        #expect(ConfigCopy.labels["model_context_length"] == "Context Window")
    }
}

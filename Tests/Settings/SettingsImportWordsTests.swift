import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #65: Import says how many settings change before it writes, and says so plainly after.
@Suite struct SettingsImportWordsTests {
    @Test func countsEachChangedValueOnce() {
        let current: JSONValue = .object(["agent": .object(["max_turns": .number(90), "verbose": .bool(false)]),
                                          "approvals": .object(["mode": .string("manual")])])
        let next: JSONValue = .object(["agent": .object(["max_turns": .number(60), "verbose": .bool(true)]),
                                       "approvals": .object(["mode": .string("manual")]),
                                       "toolsets": .array([.string("web")])])
        let patch = ConfigPath.diff(current, next)
        #expect(SettingsImportWords.changeCount(patch) == 3)
        #expect(SettingsImportWords.changeCount(ConfigPath.diff(current, current)) == 0)
    }

    @Test func wordsSayHowManyAndThatKeysStay() {
        #expect(SettingsImportWords.confirmMessage(changes: 1)
                == "1 setting on your gateway will change to the file’s values. Keys, tokens and passwords already there stay.")
        #expect(SettingsImportWords.confirmMessage(changes: 4).hasPrefix("4 settings on your gateway"))
        #expect(SettingsImportWords.done(changes: 0) == "The file matches your settings; nothing changed.")
        #expect(SettingsImportWords.done(changes: 2) == "Settings imported. 2 settings changed.")
    }
}

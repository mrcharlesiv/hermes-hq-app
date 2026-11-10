// Mac polish 2026-11-06, batch 8 (Files, Changes, Terminal and Status & Maintenance): the words and rules behind the
// fixes that can be checked without a window.

import Foundation
import Testing
@testable import HermesHQNative

struct MacPolish8Tests {
    /// #141: the Files kind column names a kind in words where its extension is no name of its own, and keeps the real
    /// abbreviations.
    @Test func kindColumnNamesKindsInWords() {
        let kind = { (name: String) in MediaKinds.kindWord(name, isDirectory: false) }
        #expect(kind("server.log") == "Log File")
        #expect(kind("deploy.sh") == "Shell Script")
        #expect(kind("yarn.lock") == "Lock File")
        #expect(kind("prod.env") == "Environment File")
        #expect(kind("main.py") == "Python Script")
        #expect(kind("App.swift") == "Swift Source")
        #expect(kind("notes.yml") == "YAML")
        // Real abbreviations, Markdown and Text as before.
        #expect(kind("huge.sql") == "SQL")
        #expect(kind("data.json") == "JSON")
        #expect(kind("report.pdf") == "PDF")
        #expect(kind("photo.jpg") == "JPEG")
        #expect(kind("README.md") == "Markdown")
        #expect(kind("notes.txt") == "Text")
        // Upper-case extensions read the same; nothing to go on is a document; a folder is a folder.
        #expect(kind("BUILD.LOG") == "Log File")
        #expect(kind("Makefile") == "Document")
        #expect(kind(".gitignore") == "Document")
        // Review: the usual env files, wherever their dots fall; a .key file is a key, not a Keynote.
        #expect(kind(".env") == "Environment File")
        #expect(kind(".env.local") == "Environment File")
        #expect(kind(".ENV.example") == "Environment File")
        #expect(kind("config/.env.production") == "Environment File")
        #expect(kind(".envrc") == "Document")
        #expect(kind("server.key") == "Key File")
        #expect(MediaKinds.kindWord("site", isDirectory: true) == "Folder")
        #expect(MediaKinds.kindWord("archive.d.log", isDirectory: true) == "Folder")
    }
}

import Foundation
import Testing
@testable import HermesHQNative

/// [toolnow] The thinking row names the step that runs, in a few words.
@Suite struct ToolNowTests {
    static func call(_ name: String, _ args: String, state: ToolCall.State = .running) -> ToolCall {
        ToolCall(id: "c-\(name)", name: name, title: name, argsText: args, summary: nil, state: state, durationSeconds: nil)
    }

    @Test func commandsKeepSudoAndMaskPasswords() {
        #expect(ToolNow.phrase(Self.call("terminal", #"{"command": "sudo env FOO=1 /usr/local/bin/brew upgrade"}"#)) == "running sudo brew upgrade")
        #expect(ToolNow.phrase(Self.call("terminal", #"{"command": "sudo mysql -u root -pHunter22 db"}"#)) == "running sudo mysql -u root -p•••• db")
        #expect(!ToolNow.phrase(Self.call("terminal", #"{"command": "mysql --password=hunter2 -e x"}"#)).contains("hunter2"))
    }

    @Test func phrases() {
        #expect(ToolNow.phrase(Self.call("terminal", #"{"command": "cd /Users/x/app && npm test"}"#)) == "running npm test")
        #expect(ToolNow.phrase(Self.call("terminal", #"{"command": "PYTHONPATH=. /usr/bin/python3 /a/b/run_checks.py --fast\nmore"}"#))
                == "running python3 run_checks.py --fast")
        #expect(ToolNow.phrase(Self.call("read_file", #"{"path": "/Users/x/app/package.json"}"#)) == "reading package.json")
        #expect(ToolNow.phrase(Self.call("web_search", #"{"query": "swift actors"}"#)) == "searching the web for swift actors")
        #expect(ToolNow.phrase(Self.call("browser_navigate", #"{"url": "https://www.apple.com/iphone/compare/"}"#)) == "opening apple.com")
        #expect(ToolNow.phrase(Self.call("image_generate", #"{"prompt": "a red fox"}"#)) == "making an image")
        #expect(ToolNow.phrase(Self.call("mcp__linear__search_issues", "{}")) == "using linear search issues")
        // Composio's say the action inside the app, never "Composio" (owner, 2026-10-29).
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_SEARCH_TOOLS", #"{"queries": []}"#)) == "looking for the right tool")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_SEARCH_TOOLS", #"{"queries": [{"use_case": "Send email"}]}"#))
                == "looking for a tool to send email")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                                         #"{"tools": [{"tool_slug": "SALESFORCE_RUN_SOQL_QUERY"}]}"#)) == "running SOQL query in Salesforce")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                                         #"{"tools": [{"tool_slug": "NOTION_SEARCH_NOTION_PAGE"}]}"#)) == "searching page in Notion")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                                         #"{"tools": [{"tool_slug": "GMAIL_FETCH_EMAILS"}, {"tool_slug": "GMAIL_LIST_LABELS"}]}"#))
                == "running 2 actions in Gmail")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL",
                                         #"{"tools": [{"tool_slug": "GOOGLECALENDAR_FIND_EVENT"}, {"tool_slug": "SLACK_SEND_MESSAGE"}]}"#))
                == "running 2 actions in Google Calenda…")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_MANAGE_CONNECTIONS", #"{"toolkits": ["googledrive"]}"#))
                == "checking the Google Drive connection")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_GET_TOOL_SCHEMAS", #"{"tool_slugs": ["GOOGLEDRIVE_DOWNLOAD_FILE"]}"#))
                == "reading how to use download file in…")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_REMOTE_WORKBENCH",
                                         #"{"code_to_execute": "r,err=run_composio_tool('GOOGLEDRIVE_DOWNLOAD_FILE',{'fileId':1})"}"#))
                == "running a script that does download…")
        #expect(ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_REMOTE_WORKBENCH", #"{"code_to_execute": "print(1)"}"#)) == "running a script")
        #expect(!ToolNow.phrase(Self.call("mcp__composio__COMPOSIO_SOMETHING_NEW", "{}")).lowercased().contains("composio"))
        // Bots reach Composio through the gateway's tool_call wrapper: the call inside is what's named.
        #expect(ToolNow.phrase(Self.call("tool_call", #"{"calls": [{"name": "mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL", "arguments": {"tools": [{"tool_slug": "GOOGLEDRIVE_FIND_FILE"}]}}]}"#))
                == "finding file in Google Drive")
        #expect(ToolLines.line(Self.call("tool_call", #"{"calls": [{"name": "mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL", "arguments": {"tools": [{"tool_slug": "GOOGLEDRIVE_FIND_FILE"}]}}]}"#)).text
                == "Finding file in Google Drive")
        #expect(ToolNow.phrase(Self.call("mcp_github_GET_ISSUE", "{}")) == "using github get issue")
        let long = ToolNow.phrase(Self.call("web_search", #"{"query": "how do I make a swiftui list scroll to the bottom on appear"}"#))
        #expect(long == "searching the web for how do I make a swiftui list scroll…")
        #expect(ToolNow.short(String(repeating: "a", count: 40)).count == ToolNow.subjectLimit)
    }

    @Test func thinkingRowFollowsTheStep() {
        func rows(_ parts: [ChatPart]) -> [ChatRow] {
            let you = ChatMessage(id: "u", role: .user, parts: [.text("go")], timestamp: Date(timeIntervalSince1970: 1_790_000_000), rowId: 1)
            var reply = ChatMessage(id: "a", role: .assistant, parts: parts, timestamp: Date(timeIntervalSince1970: 1_790_000_001), rowId: 2)
            reply.isStreaming = true
            return ChatRowBuilder.build(ChatRowBuilder.Input(messages: [you, reply], isRunning: true, botName: "Ivy", expanded: []))
        }
        func label(_ rows: [ChatRow]) -> String? {
            rows.compactMap { if case .waiting(let w) = $0.kind { return w.label } else { return nil } }.first
        }
        let running = rows([.tool(Self.call("terminal", #"{"command": "npm test"}"#))])
        #expect(label(running) == "Ivy is running npm test…")
        let between = rows([.tool(Self.call("terminal", #"{"command": "npm test"}"#, state: .done))])
        #expect(label(between) == "Ivy is running npm test…", "a finished step stays named through the thinking after it")
        let thinkingAfter = rows([.tool(Self.call("terminal", #"{"command": "npm test"}"#, state: .done)), .reasoning("Now the docs.")])
        #expect(label(thinkingAfter) == "Ivy is running npm test…")
        let next = rows([.tool(Self.call("terminal", #"{"command": "npm test"}"#, state: .done)),
                         .tool(Self.call("read_file", #"{"path": "/a/README.md"}"#))])
        #expect(label(next) == "Ivy is reading README.md…")
        #expect(label(rows([.reasoning("Let me look.")])) == "Ivy is thinking…", "before the first step")
        let writing = rows([.tool(Self.call("terminal", #"{"command": "npm test"}"#, state: .done)), .text("All green.")])
        #expect(label(writing) == nil)
    }
}

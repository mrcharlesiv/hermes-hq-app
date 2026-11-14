#if DEBUG
import Foundation

/// Scripted server requests for the DEBUG chat harness (spec 1x §3.6): `-HQDemoPrompts approval,ask,sudo` opens every
/// demo chat with those requests waiting, so previews and screenshots show the card, the dock and the sheets with no
/// gateway. An answer takes 300 ms and removes its request (Send / Skip leave the sent-answers note). Keywords:
/// `approval`, `stack` (two approvals), `long` (a 40-line command), `ask`, `asklong` (five questions of four long
/// choices: the dock at its tallest), `asktwo` (the owner's 2026-10-30 pair: a short question, then a long one),
/// `sent` / `sentskip` (that pair's answers card), `sudo`, `secret`, `unlock`, `login`, `code`.
extension FakeChatSession: ChatPrompting {
    private final class DemoPrompts {
        weak var owner: FakeChatSession?
        var prompts: ChatPrompts
        var onChange: (() -> Void)?
        var drafts: [String: ClarifyDraft] = [:]
        init(owner: FakeChatSession, prompts: ChatPrompts) { self.owner = owner; self.prompts = prompts }
    }

    private static var demoPrompts: [ObjectIdentifier: DemoPrompts] = [:]

    private var demo: DemoPrompts {
        let key = ObjectIdentifier(self)
        if let state = Self.demoPrompts[key], state.owner === self { return state }
        let state = DemoPrompts(owner: self, prompts: Self.scripted(ChatDemo.argument("-HQDemoPrompts") ?? ""))
        // `-HQDemoPromptPage N`: the dock opens on page N (screenshots of a later page's height).
        if let clarify = state.prompts.clarify, let page = ChatDemo.argument("-HQDemoPromptPage").flatMap(Int.init) {
            state.drafts[clarify.id] = ClarifyDraft(page: page)
        }
        Self.demoPrompts = Self.demoPrompts.filter { $0.value.owner != nil }
        Self.demoPrompts[key] = state
        return state
    }

    static func scripted(_ keywords: String) -> ChatPrompts {
        var out = ChatPrompts()
        let seen = Date()
        func approval(_ id: String, _ command: String, _ description: String) -> ApprovalPrompt {
            ApprovalPrompt(id: id, command: command, description: description, allowSession: true, allowAlways: true,
                           clockKey: id, firstSeen: seen)
        }
        for word in keywords.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch word {
            case "approval":
                out.approvals.append(approval("demo-approval", "git push --force origin main", "git force push"))
            case "stack":
                out.approvals.append(approval("demo-approval-1", "rm -rf build/", "recursive delete"))
                out.approvals.append(approval("demo-approval-2", "git push --force origin main", "git force push"))
            case "long":
                let script = (1...40).map { "echo \"step \($0) of the deploy script\"" }.joined(separator: "\n")
                out.approvals.append(approval("demo-approval-long", "bash <<'EOF'\n\(script)\nEOF", "shell heredoc"))
            case "ask":
                out.clarify = ClarifyPrompt(id: "demo-ask", questions: [
                    ClarifyQuestion(qid: "q0", question: "Which branch should I deploy?",
                                    choices: ["main (Recommended)", "staging"], multiSelect: false),
                    ClarifyQuestion(qid: "q1", question: "Run any checks first?",
                                    choices: ["Tests", "Lint", "Type check"], multiSelect: true),
                    ClarifyQuestion(qid: "q2", question: "What should the release be called?", choices: nil, multiSelect: false),
                ])
            case "asklong":
                let reason = "This option keeps the current layout and only changes the colors, so nothing moves on screen. "
                    + "It is the safest choice when the release is close and the screenshots are already approved."
                out.clarify = ClarifyPrompt(id: "demo-asklong", questions: (0..<5).map { i in
                    ClarifyQuestion(qid: "q\(i)", question: "Question \(i + 1) of 5: how should step \(i + 1) work? The release is close and "
                                        + "the screenshots are approved, so nothing on screen should move.\nPick the one that fits best.",
                                    choices: ["A", "B", "C", "D"].map { "Option \($0) for step \(i + 1)\n\(reason)\($0 == "A" ? " (Recommended)" : "")" },
                                    multiSelect: false)
                })
            case "askrobot":   // owner 2026-11-01: a long question with a browser chip over the dock
                out.clarify = ClarifyPrompt(id: "demo-askrobot", questions: [ClarifyQuestion(qid: "q0", question:
                    "Yes: the lifelike one that just came out is Acme's Studio Robot ($599.99, soft skin, rooted hair, walks, "
                    + "giggles, reacts to touch). The early batch is sold out, and Amazon shows it "
                    + "unavailable. A preorder now probably arrives Jan–Apr 2027, and it's rated ages 14+ as a fragile collectible. "
                    + "The newest kid version is Acme's Pocket Robot (2026): 10 inches, soft, animatronic, ages 4+, $49.97 "
                    + "on Amazon, 4.8 stars, can arrive tomorrow. Which should I set up?",
                    choices: ["Pocket Robot now ($49.97, arrives tomorrow) (Recommended)",
                              "Preorder Studio Robot ($599.99, likely next month)", "Both",
                              "Hunt for a Studio Robot that arrives sooner"],
                    multiSelect: false)])
            case "asktwo":
                out.clarify = ClarifyPrompt(id: "demo-asktwo", questions: Self.ownerPair)
            case "sent", "sentskip":
                let answers = word == "sent" ? ["Yes, fix and test both now", "Yes: pause now, then repair both"] : ["", ""]
                out.sentClarify = SentClarify(requestId: "demo-sent", rows: zip(Self.ownerPair, answers).map {
                    SentClarifyRow(question: $0.question, answer: $1)
                })
            case "sudo":
                out.values.append(ValuePrompt(id: "demo-sudo", kind: .sudo, params: ["command": "apt-get install -y ffmpeg"]))
            case "secret":
                out.values.append(ValuePrompt(id: "demo-secret", kind: .secret,
                                              params: ["env_var": "OPENWEATHER_API_KEY", "prompt": "Paste your OpenWeather key."]))
            case "unlock":
                out.values.append(ValuePrompt(id: "demo-unlock", kind: .vaultUnlock, params: ["display_name": "1Password"]))
            case "login":
                out.values.append(ValuePrompt(id: "demo-login", kind: .vaultSaveLogin,
                                              params: ["site": "Example Shop", "origin": "https://shop.example.com"]))
            case "code":
                out.values.append(ValuePrompt(id: "demo-code", kind: .vaultCode, params: ["site": "Example Shop"]))
            default: break
            }
        }
        out.approvalStackTotal = out.approvals.count
        return out
    }

    private static let ownerPair = [
        ClarifyQuestion(qid: "q0", question: "Two open failures need Hermes core changes. Can I fix and test both now?",
                        choices: ["Yes, fix and test both now (Recommended)", "Only the stuck recovery loop", "Hold both for now"],
                        multiSelect: false),
        ClarifyQuestion(qid: "q1", question: "Weekly reports on the server: should I pause the failing workers now, then repair the GitHub and "
                            + "OpenAI credentials? The repo is already backed up, and a new key would go through a secure prompt.",
                        choices: ["Yes: pause now, then repair both (Recommended)", "Pause now, repair later", "Repair GitHub only",
                                  "Leave the workers running"],
                        multiSelect: false),
    ]

    private func demoChange(after delay: Double = 0.3, _ change: @escaping (inout ChatPrompts) -> Void) async {
        try? await Task.sleep(for: .seconds(delay))
        change(&demo.prompts)
        demo.onChange?()
    }

    var prompts: ChatPrompts { demo.prompts }

    var onPromptsChange: (() -> Void)? {
        get { demo.onChange }
        set { demo.onChange = newValue }
    }

    func answerApproval(_ id: String, _ choice: ApprovalChoice) async throws {
        await demoChange { $0.approvals.removeAll { $0.id == id } }
    }

    func dismissExpiredApproval(_ id: String) {
        demo.prompts.approvals.removeAll { $0.id == id }
        demo.onChange?()
    }

    func approvalTimeout(fresh: Bool) async -> TimeInterval { ApprovalExpiry.defaultTimeout }

    func clarifyDraft(_ requestId: String) -> ClarifyDraft? { demo.drafts[requestId] }

    func saveClarifyDraft(_ requestId: String, _ draft: ClarifyDraft) { demo.drafts[requestId] = draft }

    func sendClarify(_ requestId: String, answers: [(qid: String, answer: String?)]) async throws {
        let questions = demo.prompts.clarify?.questions ?? []
        let stages = demo.drafts[requestId]?.stages ?? [:]
        await demoChange {
            $0.clarify = nil
            $0.sentClarify = SentClarify(requestId: requestId, rows: ClarifyStaging.sentRows(questions, stages))
        }
    }

    func skipClarify(_ requestId: String) async throws {
        let questions = demo.prompts.clarify?.questions ?? []
        await demoChange {
            $0.clarify = nil
            $0.sentClarify = SentClarify(requestId: requestId, rows: ClarifyStaging.sentRows(questions, [:], skipped: true))
        }
    }

    func answerValue(_ requestId: String, _ value: String) async throws {
        await demoChange { $0.values.removeAll { $0.id == requestId } }
    }

    func promptsCameOnScreen() {}

    func reconnectNow() {}
}
#endif

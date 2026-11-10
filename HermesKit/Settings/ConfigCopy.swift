// Field labels, descriptions and choice lists for the gateway's config keys, as the web app words them
// (`vendor/.../app/settings/constants.ts` FIELD_LABELS, FIELD_DESCRIPTIONS, ENUM_OPTIONS, FREE_INPUT_KEYS, plus the
// phone's own rows: `display.resume_last_session` from appearance-settings.tsx and `agent.tool_use_enforcement`'s words
// from settings-ios-list.tsx). A key with no copy here reads as its last path part, title-cased.

import Foundation

nonisolated enum ConfigCopy {
    static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// Number keys whose 0 means "work it out" (their rows read "Automatic").
    static let zeroMeansAutomatic: Set<String> = ["model_context_length"]

    static let labels: [String: String] = [
        "model": "Default Model",
        "model_context_length": "Context Window",   // [context-window] its own page now (Hermes' desktop app's name)
        "fallback_providers": "Fallback Models",
        "toolsets": "Tool Groups Bots Can Use",   // Stress test 2026-10-28 #100 (both): plain words, keys unchanged
        "timezone": "Time Zone",
        "display.personality": "Personality",
        "display.show_reasoning": "Reasoning Blocks",
        "display.resume_last_session": "Reopen Last Chat on Launch",
        "desktop.repo_scan_enabled": "Automatic Repository Discovery",
        "desktop.repo_scan_roots": "Repository Discovery Roots",
        "desktop.repo_scan_exclude_paths": "Excluded Repository Paths",
        "agent.max_turns": "Max Agent Steps",
        "agent.image_input_mode": "Image Attachments",
        "agent.api_max_retries": "API Retries",
        "agent.service_tier": "Fast Mode",   // Mac polish #133: Main Model's switch's name, for the same setting
        "agent.tool_use_enforcement": "Make Models Use Tools",
        "agent.reasoning_effort": "Reasoning Effort",
        "terminal.cwd": "Working Directory",
        "terminal.backend": "Execution Backend",
        "terminal.timeout": "Command Timeout",
        "terminal.persistent_shell": "Persistent Shell",
        "terminal.env_passthrough": "Variables Passed to Commands",
        "terminal.docker_image": "Docker Image",
        "terminal.singularity_image": "Singularity Image",
        "terminal.modal_image": "Modal Image",
        "terminal.daytona_image": "Daytona Image",
        "file_read_max_chars": "File Read Limit",
        "tool_output.max_bytes": "Terminal Output Limit",
        "tool_output.max_lines": "File Page Limit",
        "tool_output.max_line_length": "Line Length Limit",
        "code_execution.mode": "Code Execution Mode",
        "approvals.mode": "Approval Mode",
        "approvals.timeout": "Approval Timeout",
        "approvals.mcp_reload_confirm": "Ask Before Reloading Connectors",   // Stress test 2026-10-28 #100, round 2 (both)
        "command_allowlist": "Command Allowlist",
        "security.redact_secrets": "Redact Secrets",
        "security.allow_private_urls": "Web Tools Open Private Addresses",   // #105 (both): told apart from the browser's two
        "browser.allow_private_urls": "Browser Opens Private Addresses",
        "browser.auto_local_for_private_urls": "Use the Local Browser for Private Addresses",
        "browser.use_real_profile": "Use My Real Browser Profile",
        "checkpoints.enabled": "File Checkpoints",
        "checkpoints.max_snapshots": "Checkpoint Limit",
        "memory.memory_enabled": "Save Memories",   // #105 (both): not the page's own name
        "memory.user_profile_enabled": "User Profile",
        "memory.memory_char_limit": "Memory Budget",
        "memory.user_char_limit": "Profile Budget",
        "memory.provider": "Memory Provider",
        "context.engine": "Context Engine",
        "compression.enabled": "Auto-Compression",
        "compression.threshold": "Compression Threshold",
        "compression.codex_gpt55_autoraise": "Compress Later for ChatGPT Sign-In",
        "compression.target_ratio": "Compression Target",
        "compression.protect_last_n": "Protected Recent Messages",
        "auxiliary.compression.timeout": "Compression Model Timeout (s)",
        "delegation.model": "Subagent Model",
        "delegation.provider": "Subagent Provider",
        "delegation.max_iterations": "Subagent Turn Limit",
        "delegation.max_concurrent_children": "Parallel Subagents",
        "delegation.child_timeout_seconds": "Subagent Timeout",
        "delegation.reasoning_effort": "Subagent Reasoning Effort",
    ].merging(VoiceSettingsCatalog.labels) { own, _ in own }   // [talk] Settings › Voice

    /// Mac polish #132: what a list holds, for its count ("3 toolsets", "1 command"; it said "3 Items"). A list not
    /// named here counts "items".
    static let listNouns: [String: (one: String, many: String)] = [
        "toolsets": ("toolset", "toolsets"),
        "command_allowlist": ("command", "commands"),
        "terminal.env_passthrough": ("variable", "variables"),
        "desktop.repo_scan_roots": ("folder", "folders"),
        "desktop.repo_scan_exclude_paths": ("folder", "folders"),
        "fallback_providers": ("model", "models"),
    ]

    static let descriptions: [String: String] = [
        "model": "Used for new chats unless you pick a different model in the chat.",
        "model_context_length": "Overrides the detected context window of the main chat model only. Automatic uses the selected model’s own. Doesn’t affect auxiliary or Mixture of Agents models.",
        "fallback_providers": "Backup models to try, in order, if the default model fails.",
        "display.personality": "Default assistant style for new chats.",   // Mac polish #132: chats, not sessions
        "display.show_reasoning": "Show reasoning sections when the model provides them.",
        "display.resume_last_session": "When on, Hermes HQ reopens your most recent chat when it starts. Turn it off to always start on the Bots list.",
        "desktop.repo_scan_enabled": "Scan folders on \(HostWord.phrase) for Git repositories to show in Projects.",
        "desktop.repo_scan_roots": "Folders to scan. Leave empty to scan the home folder.",
        "desktop.repo_scan_exclude_paths": "Folders (and everything in them) to skip during repository discovery.",
        // Mac polish #132: its list's own choice, not "Leave it blank".
        "timezone": "The time zone Hermes works in. Choose System Default to use the time zone of \(HostWord.phrase).",
        "browser.use_real_profile": "Local browsing uses your real logins. Hermes copies your default browser’s profile (cookies, logins, preferences) into a managed snapshot and drives it with its own Chromium; your live profile is never opened directly. Only Chromium browsers (Chrome, Edge, Brave, Chromium) are supported. Off by default.",
        "agent.image_input_mode": "How image attachments are sent to the model.",
        "agent.max_turns": "The most tool-calling steps Hermes takes before it stops a run.",
        "agent.reasoning_effort": "How hard the model thinks before it answers, for models that support it.",
        "terminal.cwd": "Default project folder for tool and terminal work.",
        "terminal.persistent_shell": "Keep shell state between commands when the backend supports it.",
        "terminal.env_passthrough": "Names of environment variables that commands and tools can read.",
        "terminal.docker_image": "Container image used when the execution backend is Docker.",
        "terminal.singularity_image": "Image used when the execution backend is Singularity.",
        "terminal.modal_image": "Image used when the execution backend is Modal.",
        "terminal.daytona_image": "Image used when the execution backend is Daytona.",
        "code_execution.mode": "How strictly code execution is scoped to the current project.",
        "file_read_max_chars": "The most characters Hermes reads from a file in one request.",
        "approvals.mode": "How Hermes handles commands that need your approval.",
        "approvals.timeout": "How long approval prompts wait before timing out.",
        "security.redact_secrets": "Hide detected secrets from what the model sees, when possible.",
        "checkpoints.enabled": "Create rollback snapshots before file edits.",
        "memory.memory_enabled": "Save lasting memories that can help future chats.",
        "memory.user_profile_enabled": "Keep a compact profile of your preferences.",
        "context.engine": "How Hermes manages long conversations near the context limit.",
        "compression.enabled": "Summarize older context when conversations get large.",
        "compression.codex_gpt55_autoraise": "For models you use through a ChatGPT sign-in that allow it, wait until a chat is 85% full before summarizing it.",
        "auxiliary.compression.timeout": "How long to wait for the compression model on each call. Raise it for slow local models.",
        // Stress test 2026-10-28 #100 (both): the gateway's own words named files and values ("MEMORY.md",
        // "normal or fast", "(blank: the main model)"); these say the same in plain words.
        "agent.service_tier": "Answers sooner on providers that offer it, and may cost more.",   // Mac polish #133: the choices read Off and On now, not Fast
        "agent.tool_use_enforcement": "Push models to call tools instead of describing what they would do.",
        "memory.memory_char_limit": "How much Hermes’s saved memories can hold.",
        "memory.user_char_limit": "How much your profile can hold.",
        // Round 2 (#59, #100): the unit and default are the field's own (ConfigUnits), so the help doesn't repeat
        // them; "Enabled toolsets." and "Seconds before a command is stopped." were the gateway's words.
        "toolsets": "Groups of tools, like web search, files and the terminal, that bots can use.",
        "terminal.timeout": "How long a command can run before it is stopped.",
        "delegation.model": "Leave blank to use the main model.",
        "delegation.provider": "Leave blank to use the main model’s provider.",
        // #105 (both): three look-alike switches on two pages; each says which one it is.
        "security.allow_private_urls": "Lets web tools reach addresses on your own network, like localhost. The browser has its own switch under Browser › Local & Private URLs.",
        "browser.allow_private_urls": "Lets the browser open addresses on your own network, like localhost. Web tools have their own switch under Safety › Privacy & Network.",
        "browser.auto_local_for_private_urls": "Open private addresses with the browser on \(HostWord.phrase).",
    ].merging(VoiceSettingsCatalog.descriptions) { own, _ in own }   // [talk]

    static let enumOptions: [String: [String]] = [
        "agent.image_input_mode": ["auto", "native", "text"],
        "agent.service_tier": ["normal", "fast"],   // #100: a choice, not a box reading "normal"; any other value is kept
        "agent.reasoning_effort": reasoningEfforts,
        "approvals.mode": ["manual", "smart", "off"],
        "code_execution.mode": ["project", "strict"],
        "context.engine": ["compressor", "default", "custom"],
        "delegation.reasoning_effort": [""] + Array(reasoningEfforts.dropFirst()),
        "terminal.backend": ["local", "docker", "singularity", "modal", "daytona", "ssh"],
    ].merging(VoiceSettingsCatalog.enumOptions) { own, _ in own }   // [talk]

    /// Open-world names: the list is suggestions, a typed value is kept.
    static let freeInputKeys: Set<String> = Set([
        "tts.edge.voice", "voice.gpt_live.voice", "tts.openai.model", "tts.openai.voice", "tts.elevenlabs.voice_id",
        "tts.elevenlabs.model_id", "stt.openai.model",
    ]).union(VoiceSettingsCatalog.freeInputKeys)   // [talk]

    static let optionLabels: [String: [String: String]] = [
        "agent.tool_use_enforcement": ["auto": "Auto (Recommended)", "true": "Every Model", "false": "Never"],
        "agent.reasoning_effort": ["none": "Off", "xhigh": "Extra High"],
        "delegation.reasoning_effort": ["xhigh": "Extra High"],
        "terminal.backend": ["ssh": "SSH"],
        "agent.service_tier": ["normal": "Off", "fast": "On"],   // Mac polish #133: as Main Model's Fast Mode switch reads
    ].merging(VoiceSettingsCatalog.optionLabels) { own, _ in own }   // [talk]

    // MARK: Gateway-side groups

    /// `display.resume_last_session`'s default: on unless the record says false.
    static func resumeLastSession(_ config: JSONValue?) -> Bool {
        config.flatMap { ConfigPath.get($0, "display.resume_last_session") }?.bool != false
    }

    /// `agent.service_tier` values that mean Fast (`isFastTier`).
    static func isFastTier(_ value: JSONValue?) -> Bool {
        ["fast", "priority", "on", "ultrafast"].contains(ConfigText.text(value).trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// `agent.reasoning_effort` as its picker shows it (`false`/`disabled` read as Off; unset as Medium).
    static func reasoningEffort(_ value: JSONValue?) -> String {
        let raw = ConfigText.text(value).trimmingCharacters(in: .whitespaces).lowercased()
        if raw == "false" || raw == "disabled" { return "none" }
        return raw.isEmpty ? "medium" : raw
    }
}

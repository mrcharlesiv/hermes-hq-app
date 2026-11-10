// Names Hermes sends as ids (skill slugs, connector and plugin names, profile ids) as words on screen (Mac UX stress
// test #59): "web-search" → "Web Search", "github-pr" → "GitHub PR", "hermes-hq-browser" → "Hermes HQ Browser".
// Only what is shown changes; every value sent back to Hermes stays the id.

import Foundation

nonisolated enum DisplayName {
    /// Words that aren't plain capitalised: acronyms and brand spellings.
    static let words: [String: String] = [
        "ai": "AI", "api": "API", "aws": "AWS", "cli": "CLI", "css": "CSS", "csv": "CSV", "db": "DB", "gcp": "GCP",
        "hq": "HQ", "html": "HTML", "http": "HTTP", "id": "ID", "ios": "iOS", "js": "JS", "json": "JSON", "llm": "LLM",
        "macos": "macOS", "mcp": "MCP", "ocr": "OCR", "pdf": "PDF", "pr": "PR", "prs": "PRs", "rss": "RSS", "sdk": "SDK",
        "seo": "SEO", "sms": "SMS", "sql": "SQL", "ssh": "SSH", "stt": "STT", "svg": "SVG", "tts": "TTS", "ts": "TS",
        "ui": "UI", "url": "URL", "ux": "UX", "xml": "XML", "yaml": "YAML",
        "github": "GitHub", "gitlab": "GitLab", "openai": "OpenAI", "openrouter": "OpenRouter", "youtube": "YouTube",
        "linkedin": "LinkedIn", "imessage": "iMessage", "iphone": "iPhone", "ipad": "iPad", "whatsapp": "WhatsApp",
        "elevenlabs": "ElevenLabs", "deepseek": "DeepSeek", "hubspot": "HubSpot", "clickup": "ClickUp", "posthog": "PostHog",
        "pagerduty": "PagerDuty", "tiktok": "TikTok", "wordpress": "WordPress", "xai": "xAI", "arxiv": "arXiv",
        // Stress test 2026-10-28 #59, round 2: more brand spellings ("Duckduckgo" read as a typo).
        "duckduckgo": "DuckDuckGo", "searxng": "SearXNG", "chatgpt": "ChatGPT", "gpt": "GPT", "mysql": "MySQL",
        "postgresql": "PostgreSQL", "sqlite": "SQLite", "graphql": "GraphQL", "javascript": "JavaScript",
        "typescript": "TypeScript", "icloud": "iCloud", "applescript": "AppleScript", "mongodb": "MongoDB",
        "huggingface": "Hugging Face", "lmstudio": "LM Studio", "pypi": "PyPI", "npm": "npm", "fal": "FAL",
        "macbook": "MacBook", "imap": "IMAP", "smtp": "SMTP", "oauth": "OAuth", "jira": "Jira", "nous": "Nous",
    ]

    /// An id as a title. Text that already has capitals or spaces is someone's own spelling and is kept.
    static func title(_ id: String) -> String {
        let text = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text == text.lowercased(), !text.contains(" ") else { return text }
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard !parts.isEmpty else { return text }
        return parts.map { words[$0] ?? ($0.prefix(1).uppercased() + $0.dropFirst()) }.joined(separator: " ")
    }
}

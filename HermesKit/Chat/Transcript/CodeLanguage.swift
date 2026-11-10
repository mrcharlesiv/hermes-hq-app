// A code block's language as its card's label and VoiceOver say it (docs/spec/06-native-feel-and-design.md §2.6):
// "py" → "Python"; names that aren't one capital letter spelled out ("HCL", "CSV", "Objective-C"); plain text, none.

import Foundation

nonisolated enum CodeLanguage {
    private static let names: [String: String] = [
        "py": "Python", "python": "Python", "js": "JavaScript", "javascript": "JavaScript", "jsx": "JSX",
        "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TSX",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "shell": "Shell", "console": "Shell",
        "json": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "html": "HTML", "css": "CSS", "sql": "SQL",
        "md": "Markdown", "markdown": "Markdown", "swift": "Swift", "go": "Go", "rust": "Rust", "rs": "Rust",
        "rb": "Ruby", "ruby": "Ruby", "java": "Java", "kotlin": "Kotlin", "kt": "Kotlin", "c": "C", "cpp": "C++",
        "c++": "C++", "cs": "C#", "csharp": "C#", "php": "PHP", "diff": "Diff", "xml": "XML",
        "dockerfile": "Dockerfile", "make": "Makefile", "makefile": "Makefile", "graphql": "GraphQL", "lua": "Lua",
        "r": "R", "ini": "INI", "env": "Env",
        // Names that aren't just a capital letter ("Hcl", "Csv" and "Objective-c" read wrong).
        "hcl": "HCL", "tf": "Terraform", "terraform": "Terraform", "csv": "CSV", "tsv": "TSV",
        "objective-c": "Objective-C", "objectivec": "Objective-C", "objc": "Objective-C",
        "objective-c++": "Objective-C++", "objc++": "Objective-C++", "objcpp": "Objective-C++",
        "hpp": "C++", "cc": "C++", "cxx": "C++", "scss": "SCSS", "sass": "Sass", "less": "Less",
        "vue": "Vue", "svelte": "Svelte", "jsonc": "JSONC", "json5": "JSON5", "jsonl": "JSONL", "ndjson": "NDJSON",
        "mjs": "JavaScript", "cjs": "JavaScript", "mts": "TypeScript", "cts": "TypeScript",
        "powershell": "PowerShell", "ps1": "PowerShell", "pwsh": "PowerShell", "bat": "Batch", "cmd": "Batch",
        "proto": "Protocol Buffers", "protobuf": "Protocol Buffers", "gql": "GraphQL", "svg": "SVG",
        "tex": "LaTeX", "latex": "LaTeX", "cmake": "CMake", "ocaml": "OCaml", "ml": "OCaml", "matlab": "MATLAB",
        "fs": "F#", "fsharp": "F#", "vb": "VB", "asm": "Assembly", "wasm": "WebAssembly", "wat": "WebAssembly",
        "http": "HTTP", "applescript": "AppleScript", "kts": "Kotlin", "hs": "Haskell", "ex": "Elixir",
        "exs": "Elixir", "erl": "Erlang", "clj": "Clojure", "sol": "Solidity", "erb": "ERB", "ejs": "EJS",
        "mdx": "MDX", "rst": "reStructuredText", "adoc": "AsciiDoc", "psql": "SQL", "pgsql": "SQL", "mysql": "SQL",
        "plsql": "PL/SQL", "tsql": "T-SQL", "jsonnet": "Jsonnet", "nginx": "Nginx", "regex": "Regex",
    ]

    static func label(_ raw: String?) -> String? {
        let tag = (raw ?? "").trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        if tag.isEmpty || ["text", "plain", "plaintext", "txt", "none", "output", "log"].contains(tag) { return nil }
        if let label = names[tag] { return label }
        if tag.range(of: #"^[a-z][\w+#.-]{0,15}$"#, options: .regularExpression) != nil {
            return tag.prefix(1).uppercased() + tag.dropFirst()
        }
        return nil
    }
}

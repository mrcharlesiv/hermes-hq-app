import UIKit

// Code block syntax highlighting (spec 06 §2.6, §13 item 11): a small hand-written tokenizer for the languages of the
// code card's label map, its token kinds mapped onto the GitHub light-default / dark-dimmed palette the web's Shiki
// themes draw. Token-for-token parity with the TextMate grammars is not the goal; the colour of each kind is.
// Pure and thread-safe: it runs wherever the bubble is rendered (off the main thread for everything but a small row),
// only for settled messages (the renderer passes `highlight` only when the message no longer streams), and it changes
// colours only, never fonts, so a highlighted card has the plain card's geometry.

nonisolated enum SyntaxHighlighter {
    enum Kind: Sendable {
        case comment, keyword, string, constant, entity, function, tag, invalid, inserted, deleted, heading, range
    }

    struct Token: Sendable {
        var range: NSRange
        var kind: Kind
    }

    /// The web's limits: bigger code stays plain (`shiki-highlighter.tsx:45-47`).
    static let maxCharacters = 150_000
    static let maxLines = 3_000

    /// Tokens for `code` in `language` (the fence's tag), cached by (language, code). Nil for an unknown or plain tag.
    static func tokens(_ code: String, language: String?) -> [Token]? {
        guard let lang = Lang(tag: language) else { return nil }
        let units = Array(code.utf16)
        guard units.count <= maxCharacters, units.reduce(0, { $1 == 10 ? $0 + 1 : $0 }) < maxLines else { return nil }
        let key = CacheKey(lang: lang, code: code)
        if let hit = cache.value(key) { return hit }
        var lexer = Lexer(units: units, lang: lang)
        let out = lexer.run()
        cache.set(key, out, cost: units.count)
        return out
    }

    /// Colours `text` (the code card's attributed string, whose string is `code`) in place.
    static func apply(_ tokens: [Token], to text: NSMutableAttributedString) {
        let length = text.length
        for token in tokens where token.range.location + token.range.length <= length {
            text.addAttribute(.foregroundColor, value: SyntaxPalette.color(token.kind), range: token.range)
        }
    }

    // MARK: Cache (the web's: 512 entries, 6 M characters)

    private struct CacheKey: Hashable { var lang: Lang; var code: String }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CacheKey: [Token]] = [:]
        private var order: [CacheKey] = []
        private var characters = 0

        func value(_ key: CacheKey) -> [Token]? { lock.lock(); defer { lock.unlock() }; return values[key] }

        func set(_ key: CacheKey, _ value: [Token], cost: Int) {
            lock.lock(); defer { lock.unlock() }
            if values[key] == nil { order.append(key); characters += cost }
            values[key] = value
            while order.count > 512 || characters > 6_000_000, !order.isEmpty {
                let old = order.removeFirst()
                characters -= old.code.utf16.count
                values[old] = nil
            }
        }
    }

    private static let cache = Cache()
}

// MARK: - Palette (spec 06 §2.6 table; the dark column has the web's saturate/brightness filter applied)

/// GitHub's colours, or a skin's own (`ThemeTokens.syntax`, Rosé Pine's), read from the theme at draw time.
nonisolated enum SyntaxPalette {
    private static func c(_ light: UInt32, _ dark: UInt32, _ own: KeyPath<SyntaxColours, RGBA> & Sendable) -> UIColor {
        UIColor { @Sendable traits in
            let isDark = traits.userInterfaceStyle == .dark
            let skin = ThemeTable.withSet(generation: traits[ThemeGenerationTrait.self]) { $0.tokens(dark: isDark).syntax?[keyPath: own] }
            return skin?.uiColor ?? hex(isDark ? dark : light)
        }
    }
    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let comment = c(0x57606A, 0x6E7882, \.comment)
    static let keyword = c(0xCF222E, 0xCF6C65, \.keyword)
    static let string = c(0x0A3069, 0x92BEE1, \.string)
    static let constant = c(0x0550AE, 0x6EA6DD, \.constant)
    static let entity = c(0x953800, 0xD69359, \.entity)
    static let function = c(0x8250DF, 0xC7B0DE, \.function)
    static let tag = c(0x116329, 0x8BC68A, \.tag)
    static let invalid = c(0x82071E, 0xDC8B84, \.invalid)

    static func color(_ kind: SyntaxHighlighter.Kind) -> UIColor {
        switch kind {
        case .comment: comment
        case .keyword: keyword
        case .string: string
        case .constant, .heading: constant
        case .entity: entity
        case .function, .range: function
        case .tag, .inserted: tag
        case .invalid, .deleted: invalid
        }
    }
}

// MARK: - Languages

nonisolated private enum Family: Hashable, Sendable {
    case code          // C-like and friends: comments, strings, numbers, keywords, calls
    case json, yaml, toml, html, css, diff, markdown, shell, dockerfile, makefile, sql
}

nonisolated private struct Lang: Hashable, Sendable {
    var name: String
    var family: Family

    init?(tag: String?) {
        let t = (tag ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "py", "python", "python3", "py3", "gyp": self.init("python", .code)
        case "js", "javascript", "jsx", "mjs", "cjs", "node": self.init("javascript", .code)
        case "ts", "typescript", "tsx", "mts", "cts": self.init("typescript", .code)
        case "swift": self.init("swift", .code)
        case "go", "golang": self.init("go", .code)
        case "rust", "rs": self.init("rust", .code)
        case "rb", "ruby": self.init("ruby", .code)
        case "java": self.init("java", .code)
        case "kotlin", "kt", "kts": self.init("kotlin", .code)
        case "c", "h": self.init("c", .code)
        case "cpp", "c++", "cc", "cxx", "hpp", "hh": self.init("cpp", .code)
        case "cs", "csharp", "c#": self.init("csharp", .code)
        case "php": self.init("php", .code)
        case "lua": self.init("lua", .code)
        case "r": self.init("r", .code)
        case "graphql", "gql": self.init("graphql", .code)
        case "dart": self.init("dart", .code)
        case "scala": self.init("scala", .code)
        case "objc", "objective-c", "m": self.init("c", .code)
        case "json", "jsonc", "json5", "jsonl": self.init("json", .json)
        case "yaml", "yml": self.init("yaml", .yaml)
        case "toml", "ini", "cfg", "conf", "properties": self.init("toml", .toml)
        case "html", "htm", "xhtml", "xml", "svg", "plist", "xsd", "vue", "svelte": self.init("html", .html)
        case "css", "scss", "less", "sass": self.init("css", .css)
        case "diff", "patch": self.init("diff", .diff)
        case "md", "markdown", "mdx": self.init("markdown", .markdown)
        case "sh", "bash", "zsh", "shell", "console", "shellscript", "ksh", "fish", "terminal": self.init("shell", .shell)
        case "dockerfile", "docker", "containerfile": self.init("dockerfile", .dockerfile)
        case "make", "makefile", "mk": self.init("makefile", .makefile)
        case "sql", "mysql", "postgres", "postgresql", "pgsql", "sqlite", "plsql", "tsql": self.init("sql", .sql)
        default: return nil          // "text", "plain", "env", "log", unknown tags: plain (spec 06 §2.6)
        }
    }

    private init(_ name: String, _ family: Family) { self.name = name; self.family = family }

    var lineComments: [String] {
        switch name {
        case "python", "ruby", "r": ["#"]
        case "lua": ["--"]
        case "php": ["//", "#"]
        case "graphql": ["#"]
        default: ["//"]
        }
    }

    var blockComment: (String, String)? {
        switch name {
        case "python", "ruby", "r", "graphql": nil
        case "lua": ("--[[", "]]")
        default: ("/*", "*/")
        }
    }

    var quotes: Set<UInt16> {
        switch name {
        case "javascript", "typescript", "go", "kotlin", "dart", "scala": [34, 39, 96]     // " ' `
        case "rust", "java", "c", "cpp", "csharp", "swift": [34, 39]
        default: [34, 39]
        }
    }

    var tripleQuotes: Bool { ["python", "swift", "kotlin", "scala", "dart"].contains(name) }

    /// Words after which the next identifier names a function / a type.
    var defWords: Set<String> { ["def", "func", "function", "fn", "fun", "sub", "method"] }
    var typeWords: Set<String> {
        ["class", "struct", "enum", "interface", "protocol", "trait", "impl", "type", "extension", "record", "union",
         "object", "module", "namespace", "actor", "typealias"]
    }

    /// Capitalised identifiers read as types.
    var capitalisedTypes: Bool { !["python", "ruby", "lua", "r", "php"].contains(name) }

    var keywords: Set<String> { Lang.keywordTable[name] ?? [] }
    var constants: Set<String> { Lang.constantTable[name] ?? Lang.commonConstants }
    var builtins: Set<String> { Lang.builtinTable[name] ?? [] }

    static let commonConstants: Set<String> = ["true", "false", "null", "nil", "undefined", "NaN", "Infinity", "this", "self", "super"]

    static let constantTable: [String: Set<String>] = [
        "python": ["True", "False", "None", "self", "cls", "NotImplemented", "Ellipsis", "__name__", "__main__", "__file__"],
        "ruby": ["true", "false", "nil", "self", "super", "__FILE__", "__LINE__"],
        "lua": ["true", "false", "nil", "self"],
        "r": ["TRUE", "FALSE", "NULL", "NA", "Inf", "NaN", "T", "F"],
        "go": ["true", "false", "nil", "iota"],
        "rust": ["true", "false", "self", "Self", "super", "crate", "None", "Some", "Ok", "Err"],
        "swift": ["true", "false", "nil", "self", "Self", "super"],
        "php": ["true", "false", "null", "TRUE", "FALSE", "NULL", "this", "self", "parent"],
        "graphql": ["true", "false", "null"],
    ]

    static let builtinTable: [String: Set<String>] = [
        "python": ["print", "len", "range", "open", "str", "int", "float", "list", "dict", "set", "tuple", "bool", "type",
                   "isinstance", "enumerate", "zip", "map", "filter", "sorted", "sum", "min", "max", "abs", "any", "all",
                   "input", "super", "object", "Exception", "ValueError", "KeyError", "TypeError", "RuntimeError", "repr",
                   "getattr", "setattr", "hasattr", "iter", "next", "round", "format", "bytes", "id", "hash", "vars"],
        "javascript": ["console", "window", "document", "Math", "JSON", "Promise", "Object", "Array", "String", "Number",
                       "Boolean", "Error", "Map", "Set", "Date", "RegExp", "Symbol", "process", "require", "module", "exports",
                       "globalThis", "fetch", "setTimeout", "clearTimeout", "setInterval", "parseInt", "parseFloat"],
        "typescript": ["console", "window", "document", "Math", "JSON", "Promise", "Object", "Array", "String", "Number",
                       "Boolean", "Error", "Map", "Set", "Date", "RegExp", "Symbol", "process", "require", "module",
                       "Record", "Partial", "Readonly", "Pick", "Omit", "fetch", "setTimeout", "parseInt", "parseFloat",
                       "string", "number", "boolean", "any", "unknown", "never", "void", "object", "bigint", "symbol"],
        "go": ["fmt", "len", "cap", "make", "new", "append", "copy", "delete", "panic", "recover", "print", "println",
               "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float32",
               "float64", "bool", "byte", "rune", "error", "any", "complex64", "complex128", "uintptr"],
        "rust": ["println", "print", "format", "vec", "panic", "assert", "assert_eq", "eprintln", "write", "writeln",
                 "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64",
                 "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"],
        "c": ["printf", "scanf", "malloc", "free", "sizeof", "NULL", "int", "char", "float", "double", "long", "short",
              "unsigned", "signed", "void", "size_t", "bool", "uint8_t", "uint32_t", "int32_t", "uint64_t", "FILE"],
        "cpp": ["std", "cout", "cin", "endl", "printf", "malloc", "free", "sizeof", "nullptr", "int", "char", "float",
                "double", "long", "short", "unsigned", "signed", "void", "bool", "size_t", "string", "vector", "auto"],
        "lua": ["print", "pairs", "ipairs", "require", "table", "string", "math", "os", "io", "type", "tostring", "tonumber"],
        "ruby": ["puts", "print", "require", "require_relative", "attr_accessor", "attr_reader", "attr_writer", "raise", "p"],
        "php": ["echo", "print", "isset", "unset", "empty", "array", "count", "strlen", "explode", "implode", "die"],
        "r": ["print", "c", "library", "function", "data.frame", "list", "paste", "cat", "length", "sum", "mean"],
        "swift": ["print", "Int", "String", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Character",
                  "Optional", "Void", "Any", "AnyObject", "Never", "Error", "Result", "UInt", "CGFloat"],
        "java": ["System", "String", "Integer", "Object", "List", "Map", "int", "long", "double", "float", "boolean",
                 "char", "byte", "short", "void"],
        "kotlin": ["println", "print", "listOf", "mapOf", "setOf", "mutableListOf", "Int", "String", "Long", "Double",
                   "Boolean", "Unit", "Any", "Nothing"],
        "csharp": ["Console", "string", "int", "long", "double", "float", "bool", "char", "byte", "object", "void",
                   "decimal", "var", "List", "Dictionary", "Task"],
    ]

    static let keywordTable: [String: Set<String>] = [
        "python": ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                   "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
                   "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case"],
        "javascript": ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                       "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if", "import",
                       "in", "instanceof", "let", "new", "of", "return", "static", "switch", "throw", "try", "typeof",
                       "var", "void", "while", "with", "yield", "get", "set", "as"],
        "typescript": ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
                       "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for",
                       "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "is", "keyof",
                       "let", "namespace", "new", "of", "private", "protected", "public", "readonly", "return",
                       "satisfies", "static", "switch", "throw", "try", "type", "typeof", "var", "while", "yield"],
        "swift": ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
                  "convenience", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                  "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is",
                  "lazy", "let", "mutating", "nonisolated", "open", "operator", "override", "private", "protocol",
                  "public", "repeat", "required", "rethrows", "return", "some", "static", "struct", "subscript",
                  "switch", "throw", "throws", "try", "typealias", "var", "weak", "where", "while", "unowned",
                  "isolated", "consuming", "borrowing", "sending"],
        "go": ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
               "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
               "switch", "type", "var"],
        "rust": ["as", "async", "await", "break", "const", "continue", "dyn", "else", "enum", "extern", "fn", "for", "if",
                 "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "static", "struct",
                 "trait", "type", "unsafe", "use", "where", "while", "macro_rules"],
        "ruby": ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end",
                 "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "then",
                 "undef", "unless", "until", "when", "while", "yield", "private", "protected", "public"],
        "java": ["abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else",
                 "enum", "extends", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof",
                 "interface", "native", "new", "package", "private", "protected", "public", "record", "return",
                 "static", "strictfp", "switch", "synchronized", "throw", "throws", "transient", "try", "var",
                 "volatile", "while", "yield", "sealed", "permits"],
        "kotlin": ["abstract", "as", "break", "by", "catch", "class", "companion", "const", "continue", "data", "do",
                   "else", "enum", "external", "final", "finally", "for", "fun", "if", "import", "in", "init", "inline",
                   "interface", "internal", "is", "lateinit", "object", "open", "operator", "out", "override",
                   "package", "private", "protected", "public", "return", "sealed", "suspend", "throw", "try",
                   "typealias", "val", "var", "vararg", "when", "where", "while"],
        "c": ["auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto",
              "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef",
              "union", "volatile", "while", "#include", "#define", "#ifdef", "#ifndef", "#endif", "#if", "#else",
              "#pragma", "#import"],
        "cpp": ["alignas", "auto", "break", "case", "catch", "class", "const", "constexpr", "continue", "decltype",
                "default", "delete", "do", "else", "enum", "explicit", "export", "extern", "for", "friend", "goto", "if",
                "inline", "mutable", "namespace", "new", "noexcept", "operator", "private", "protected", "public",
                "return", "sizeof", "static", "struct", "switch", "template", "throw", "try", "typedef", "typename",
                "union", "using", "virtual", "volatile", "while", "override", "final", "#include", "#define",
                "#ifdef", "#ifndef", "#endif", "#if", "#else", "#pragma"],
        "csharp": ["abstract", "as", "async", "await", "base", "break", "case", "catch", "class", "const", "continue",
                   "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "finally", "fixed", "for",
                   "foreach", "goto", "if", "implicit", "in", "interface", "internal", "is", "lock", "namespace", "new",
                   "operator", "out", "override", "params", "private", "protected", "public", "readonly", "record",
                   "ref", "return", "sealed", "sizeof", "static", "struct", "switch", "throw", "try", "typeof",
                   "unsafe", "using", "virtual", "volatile", "while", "yield", "get", "set", "init"],
        "php": ["abstract", "and", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare",
                "default", "do", "else", "elseif", "enum", "extends", "final", "finally", "fn", "for", "foreach",
                "function", "global", "if", "implements", "include", "include_once", "instanceof", "interface",
                "match", "namespace", "new", "or", "private", "protected", "public", "readonly", "require",
                "require_once", "return", "static", "switch", "throw", "trait", "try", "use", "var", "while", "yield"],
        "lua": ["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not",
                "or", "repeat", "return", "then", "until", "while"],
        "r": ["if", "else", "repeat", "while", "function", "for", "in", "next", "break", "return"],
        "graphql": ["query", "mutation", "subscription", "fragment", "on", "type", "input", "enum", "interface", "union",
                    "scalar", "schema", "extend", "implements", "directive"],
        "dart": ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                 "do", "else", "enum", "export", "extends", "extension", "factory", "final", "finally", "for", "if",
                 "implements", "import", "in", "is", "late", "library", "mixin", "new", "required", "return", "static",
                 "super", "switch", "throw", "try", "var", "void", "while", "with", "yield"],
        "scala": ["abstract", "case", "catch", "class", "def", "do", "else", "extends", "final", "finally", "for",
                  "if", "implicit", "import", "lazy", "match", "new", "object", "override", "package", "private",
                  "protected", "return", "sealed", "trait", "try", "type", "val", "var", "while", "with", "yield"],
    ]
}

// MARK: - Lexer

nonisolated private struct Lexer {
    let u: [UInt16]
    let lang: Lang
    var i = 0
    var out: [SyntaxHighlighter.Token] = []

    init(units: [UInt16], lang: Lang) { u = units; self.lang = lang }

    // UTF-16 code units of the characters the lexer looks at.
    static let nl: UInt16 = 10, cr: UInt16 = 13, space: UInt16 = 32, tab: UInt16 = 9
    static let dq: UInt16 = 34, sq: UInt16 = 39, bt: UInt16 = 96, bs: UInt16 = 92
    static let hash: UInt16 = 35, dollar: UInt16 = 36, at: UInt16 = 64, colon: UInt16 = 58, eq: UInt16 = 61
    static let lparen: UInt16 = 40, lt: UInt16 = 60, gt: UInt16 = 62, slash: UInt16 = 47, dash: UInt16 = 45
    static let plus: UInt16 = 43, lbracket: UInt16 = 91, rbracket: UInt16 = 93, lbrace: UInt16 = 123, rbrace: UInt16 = 125
    static let dot: UInt16 = 46, bang: UInt16 = 33, star: UInt16 = 42, underscore: UInt16 = 95, gtSign: UInt16 = 62

    mutating func run() -> [SyntaxHighlighter.Token] {
        switch lang.family {
        case .code: code()
        case .json: json()
        case .yaml: yaml()
        case .toml: toml()
        case .html: html()
        case .css: css()
        case .diff: diff()
        case .markdown: markdown()
        case .shell: shell()
        case .dockerfile: dockerfile()
        case .makefile: makefile()
        case .sql: sql()
        }
        return out
    }

    // MARK: Helpers

    mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxHighlighter.Kind) {
        guard end > start else { return }
        out.append(.init(range: NSRange(location: start, length: end - start), kind: kind))
    }

    func at(_ k: Int) -> UInt16? { k < u.count ? u[k] : nil }

    func starts(_ s: String, at k: Int) -> Bool {
        var j = k
        for c in s.utf16 {
            guard j < u.count, u[j] == c else { return false }
            j += 1
        }
        return true
    }

    static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == underscore || c >= 0x80
    }
    static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab }

    func lineEnd(from k: Int) -> Int {
        var j = k
        while j < u.count, u[j] != Lexer.nl { j += 1 }
        return j
    }

    func word(_ s: Int, _ e: Int) -> String { String(utf16CodeUnits: Array(u[s..<e]), count: e - s) }

    /// A quoted string from `i` (on the quote): to the unescaped closing quote, the end of the line for a one-line
    /// quote, or the end for a backtick/triple quote.
    mutating func quoted(multiline: Bool = false) -> Int {
        let q = u[i]
        let start = i
        if lang.tripleQuotes, starts(String(repeating: Character(UnicodeScalar(UInt8(q))), count: 3), at: i) {
            let close = String(repeating: Character(UnicodeScalar(UInt8(q))), count: 3)
            var j = i + 3
            while j < u.count, !starts(close, at: j) { j += u[j] == Lexer.bs ? 2 : 1 }
            j = min(u.count, j + 3)
            emit(start, j, .string)
            return j
        }
        var j = i + 1
        let spans = multiline || q == Lexer.bt
        while j < u.count {
            let c = u[j]
            if c == Lexer.bs { j += 2; continue }
            if c == q { j += 1; break }
            if c == Lexer.nl && !spans { break }
            j += 1
        }
        j = min(j, u.count)
        emit(start, j, .string)
        return j
    }

    /// A number from `i`: digits, hex/octal/binary prefixes, separators, a fraction and an exponent, a type suffix.
    func numberEnd(_ k: Int) -> Int {
        var j = k
        if at(j) == 48, let x = at(j + 1), x == 120 || x == 88 || x == 98 || x == 66 || x == 111 || x == 79 {
            j += 2
            while let c = at(j), Lexer.isIdent(c) { j += 1 }
            return j
        }
        while let c = at(j), Lexer.isDigit(c) || c == Lexer.underscore { j += 1 }
        if at(j) == Lexer.dot, let d = at(j + 1), Lexer.isDigit(d) {
            j += 1
            while let c = at(j), Lexer.isDigit(c) || c == Lexer.underscore { j += 1 }
        }
        if let e = at(j), e == 101 || e == 69 {
            var k2 = j + 1
            if let s = at(k2), s == Lexer.plus || s == Lexer.dash { k2 += 1 }
            if let d = at(k2), Lexer.isDigit(d) {
                j = k2
                while let c = at(j), Lexer.isDigit(c) { j += 1 }
            }
        }
        while let c = at(j), Lexer.isIdentStart(c), c < 0x80 { j += 1 }     // 10u, 1.5f, 3i64
        return j
    }

    /// The next non-space character after `k` on the same line.
    func nextSolid(_ k: Int) -> UInt16? {
        var j = k
        while let c = at(j), Lexer.isSpace(c) { j += 1 }
        return at(j)
    }

    // MARK: C-like and friends

    mutating func code() {
        let lineComments = lang.lineComments
        let block = lang.blockComment
        let quotes = lang.quotes
        let keywords = lang.keywords, constants = lang.constants, builtins = lang.builtins
        let defWords = lang.defWords, typeWords = lang.typeWords
        var pending: SyntaxHighlighter.Kind?     // the next identifier's kind (after `def`, `class`)
        var lineStart = true
        while i < u.count {
            let c = u[i]
            if c == Lexer.nl { i += 1; lineStart = true; continue }
            if Lexer.isSpace(c) || c == Lexer.cr { i += 1; continue }
            defer { lineStart = false }
            if let (open, close) = block, starts(open, at: i) {
                var j = i + open.utf16.count
                while j < u.count, !starts(close, at: j) { j += 1 }
                j = min(u.count, j + close.utf16.count)
                emit(i, j, .comment); i = j; continue
            }
            if lineComments.contains(where: { starts($0, at: i) }) {
                // C preprocessor lines are directives, not comments.
                let j = lineEnd(from: i)
                emit(i, j, .comment); i = j; continue
            }
            if lineStart, c == Lexer.hash, ["c", "cpp"].contains(lang.name) {
                var j = i + 1
                while let d = at(j), Lexer.isIdent(d) { j += 1 }
                emit(i, j, .keyword)
                i = j
                if let q = nextSolid(i), q == Lexer.lt || q == Lexer.dq {
                    while let s = at(i), Lexer.isSpace(s) { i += 1 }
                    let close: UInt16 = q == Lexer.lt ? Lexer.gt : Lexer.dq
                    var k = i + 1
                    while let d = at(k), d != close, d != Lexer.nl { k += 1 }
                    k = min(u.count, k + 1)
                    emit(i, k, .string); i = k
                }
                continue
            }
            if quotes.contains(c) { i = quoted(); pending = nil; continue }
            if Lexer.isDigit(c) || (c == Lexer.dot && (at(i + 1).map(Lexer.isDigit) ?? false)) {
                let j = numberEnd(i)
                emit(i, j, .constant); i = j; continue
            }
            if c == Lexer.at, let n = at(i + 1), Lexer.isIdentStart(n) {
                // Decorators and annotations (@property, @Override, @MainActor).
                var j = i + 1
                while let d = at(j), Lexer.isIdent(d) || d == Lexer.dot { j += 1 }
                emit(i, j, .function); i = j; continue
            }
            if c == Lexer.dollar, ["php"].contains(lang.name), let n = at(i + 1), Lexer.isIdentStart(n) {
                var j = i + 1
                while let d = at(j), Lexer.isIdent(d) { j += 1 }
                i = j; continue                                   // variable.other: theme foreground
            }
            if Lexer.isIdentStart(c) || c == Lexer.dollar {
                var j = i + 1
                while let d = at(j), Lexer.isIdent(d) || d == Lexer.dollar { j += 1 }
                // Ruby's `defined?`, macros `println!` (Rust).
                if lang.name == "ruby", at(j) == 63 { j += 1 }
                let w = word(i, j)
                // Python string prefixes: f"…", r'…', b"…".
                if lang.name == "python", w.count <= 2, w.allSatisfy({ "rRbBfFuU".contains($0) }), let q = at(j), quotes.contains(q) {
                    let start = i
                    i = j
                    let end = quoted()
                    emit(start, j, .string)
                    i = end
                    continue
                }
                if let kind = pending {
                    emit(i, j, kind)
                    pending = nil
                } else if keywords.contains(w) {
                    emit(i, j, .keyword)
                    if defWords.contains(w) { pending = .function } else if typeWords.contains(w) { pending = .entity }
                } else if constants.contains(w) {
                    emit(i, j, .constant)
                } else if lang.name == "rust", at(j) == Lexer.bang {
                    emit(i, j + 1, .function); j += 1               // println!
                } else if nextSolid(j) == Lexer.lparen {
                    emit(i, j, builtins.contains(w) ? .constant : .function)
                } else if builtins.contains(w) {
                    emit(i, j, .constant)
                } else if lang.capitalisedTypes, let f = w.utf16.first, f >= 65, f <= 90, w.count > 1 {
                    emit(i, j, w.uppercased() == w && w.count > 2 ? .constant : .entity)   // CONST vs Type
                }
                i = j
                continue
            }
            i += 1
        }
    }

    // MARK: JSON

    mutating func json() {
        while i < u.count {
            let c = u[i]
            if c == Lexer.dq {
                let e = quoted()
                // A key: the string is followed by a colon.
                if nextSolid(e) == Lexer.colon { out[out.count - 1].kind = .tag }
                i = e; continue
            }
            if starts("//", at: i) { let j = lineEnd(from: i); emit(i, j, .comment); i = j; continue }
            if Lexer.isDigit(c) || c == Lexer.dash {
                let j = numberEnd(c == Lexer.dash ? i + 1 : i)
                if j > i + (c == Lexer.dash ? 1 : 0) { emit(i, j, .constant); i = j; continue }
            }
            if Lexer.isIdentStart(c) {
                var j = i
                while let d = at(j), Lexer.isIdent(d) { j += 1 }
                if ["true", "false", "null"].contains(word(i, j)) { emit(i, j, .constant) }
                i = j; continue
            }
            i += 1
        }
    }

    // MARK: YAML

    mutating func yaml() {
        while i < u.count {
            let end = lineEnd(from: i)
            var k = i
            while k < end, Lexer.isSpace(u[k]) { k += 1 }
            if k < end, u[k] == Lexer.hash { emit(k, end, .comment); i = end + 1; continue }
            if starts("---", at: k) || starts("...", at: k) { emit(k, min(end, k + 3), .keyword); i = end + 1; continue }
            if k < end, u[k] == Lexer.dash, k + 1 < end, Lexer.isSpace(u[k + 1]) { k += 2 }
            // key: value
            var keyEnd = k
            if k < end, u[k] == Lexer.dq || u[k] == Lexer.sq {
                let q = u[k]; keyEnd = k + 1
                while keyEnd < end, u[keyEnd] != q { keyEnd += 1 }
                keyEnd = min(end, keyEnd + 1)
            } else {
                while keyEnd < end, u[keyEnd] != Lexer.colon, u[keyEnd] != Lexer.hash { keyEnd += 1 }
            }
            var v = k
            if keyEnd < end, u[keyEnd] == Lexer.colon, keyEnd + 1 >= end || Lexer.isSpace(u[keyEnd + 1]) {
                emit(k, keyEnd, .tag)
                v = keyEnd + 1
            }
            scalar(from: v, to: end)
            i = end + 1
        }
    }

    /// A YAML / TOML value: comments, strings, numbers, booleans.
    mutating func scalar(from s: Int, to end: Int) {
        var k = s
        while k < end {
            let c = u[k]
            if Lexer.isSpace(c) { k += 1; continue }
            if c == Lexer.hash, k == s || (k > 0 && Lexer.isSpace(u[k - 1])) { emit(k, end, .comment); return }
            if c == Lexer.dq || c == Lexer.sq {
                var j = k + 1
                while j < end, u[j] != c { j += u[j] == Lexer.bs && c == Lexer.dq ? 2 : 1 }
                j = min(end, j + 1)
                emit(k, j, .string); k = j; continue
            }
            if c == 38 || c == Lexer.star, k + 1 < end, Lexer.isIdentStart(u[k + 1]) {      // &anchor, *alias
                var j = k + 1
                while j < end, Lexer.isIdent(u[j]) || u[j] == Lexer.dash { j += 1 }
                emit(k, j, .entity); k = j; continue
            }
            var j = k
            while j < end, !Lexer.isSpace(u[j]), u[j] != 44, u[j] != Lexer.rbracket, u[j] != Lexer.rbrace { j += 1 }
            let w = word(k, j)
            if ["true", "false", "null", "yes", "no", "on", "off", "~", "True", "False", "Null", "TRUE", "FALSE"].contains(w)
                || Double(w.replacingOccurrences(of: "_", with: "")) != nil {
                emit(k, j, .constant)
            } else if lang.family == .yaml, k == s || (k > s && !Lexer.isSpace(u[k - 1])) {
                // a plain scalar: the theme's string colour
                var e = end
                while e > k, Lexer.isSpace(u[e - 1]) { e -= 1 }
                if let c = (k..<e).first(where: { u[$0] == Lexer.hash && $0 > k && Lexer.isSpace(u[$0 - 1]) }) {
                    var ce = c
                    while ce > k, Lexer.isSpace(u[ce - 1]) { ce -= 1 }
                    emit(k, ce, .string); emit(c, end, .comment); return
                }
                emit(k, e, .string); return
            }
            k = max(j, k + 1)
        }
    }

    // MARK: TOML / INI

    mutating func toml() {
        while i < u.count {
            let end = lineEnd(from: i)
            var k = i
            while k < end, Lexer.isSpace(u[k]) { k += 1 }
            if k < end, u[k] == Lexer.hash || u[k] == 59 { emit(k, end, .comment); i = end + 1; continue }    // # ;
            if k < end, u[k] == Lexer.lbracket {
                var j = k
                while j < end, u[j] != Lexer.rbracket { j += 1 }
                emit(k, min(end, j + 1), .entity); i = end + 1; continue
            }
            var e = k
            while e < end, u[e] != Lexer.eq { e += 1 }
            if e < end {
                var ke = e
                while ke > k, Lexer.isSpace(u[ke - 1]) { ke -= 1 }
                emit(k, ke, .constant)
                scalar(from: e + 1, to: end)
            }
            i = end + 1
        }
    }

    // MARK: HTML / XML

    mutating func html() {
        while i < u.count {
            if starts("<!--", at: i) {
                var j = i + 4
                while j < u.count, !starts("-->", at: j) { j += 1 }
                j = min(u.count, j + 3)
                emit(i, j, .comment); i = j; continue
            }
            if u[i] == Lexer.lt, let n = at(i + 1), Lexer.isIdentStart(n) || n == Lexer.slash || n == Lexer.bang || n == 63 {
                var j = i + 1
                if let d = at(j), d == Lexer.slash || d == Lexer.bang || d == 63 { j += 1 }
                let nameStart = j
                while let d = at(j), Lexer.isIdent(d) || d == Lexer.dash || d == Lexer.colon || d == Lexer.dot { j += 1 }
                emit(nameStart, j, .tag)
                // Attributes until '>'.
                while j < u.count, u[j] != Lexer.gt {
                    let d = u[j]
                    if d == Lexer.dq || d == Lexer.sq {
                        var k = j + 1
                        while k < u.count, u[k] != d { k += 1 }
                        k = min(u.count, k + 1)
                        emit(j, k, .string); j = k; continue
                    }
                    if Lexer.isIdentStart(d) {
                        var k = j
                        while let e = at(k), Lexer.isIdent(e) || e == Lexer.dash || e == Lexer.colon { k += 1 }
                        emit(j, k, .constant); j = k; continue
                    }
                    j += 1
                }
                i = min(u.count, j + 1); continue
            }
            if u[i] == 38 {                                    // &amp;
                var j = i + 1
                while let d = at(j), Lexer.isIdent(d) || d == Lexer.hash { j += 1 }
                if at(j) == 59 { emit(i, j + 1, .constant); i = j + 1; continue }
            }
            i += 1
        }
    }

    // MARK: CSS

    mutating func css() {
        var depth = 0
        while i < u.count {
            let c = u[i]
            if starts("/*", at: i) {
                var j = i + 2
                while j < u.count, !starts("*/", at: j) { j += 1 }
                j = min(u.count, j + 2)
                emit(i, j, .comment); i = j; continue
            }
            if c == Lexer.lbrace { depth += 1; i += 1; continue }
            if c == Lexer.rbrace { depth = max(0, depth - 1); i += 1; continue }
            if c == Lexer.dq || c == Lexer.sq { i = quoted(); continue }
            if c == Lexer.at, let n = at(i + 1), Lexer.isIdentStart(n) {
                var j = i + 1
                while let d = at(j), Lexer.isIdent(d) || d == Lexer.dash { j += 1 }
                emit(i, j, .keyword); i = j; continue
            }
            if depth == 0 {
                // Selectors: .class / #id / [attr] read as attributes; element names as tags.
                if c == Lexer.dot || c == Lexer.hash {
                    var j = i + 1
                    while let d = at(j), Lexer.isIdent(d) || d == Lexer.dash { j += 1 }
                    emit(i, j, .constant); i = j; continue
                }
                if Lexer.isIdentStart(c) {
                    var j = i
                    while let d = at(j), Lexer.isIdent(d) || d == Lexer.dash { j += 1 }
                    emit(i, j, .tag); i = j; continue
                }
                i += 1; continue
            }
            if Lexer.isIdentStart(c) || c == Lexer.dash {
                var j = i
                while let d = at(j), Lexer.isIdent(d) || d == Lexer.dash { j += 1 }
                if nextSolid(j) == Lexer.colon { emit(i, j, .constant) }                     // property name
                else if nextSolid(j) == Lexer.lparen { emit(i, j, .function) }               // rgb(), var()
                else if word(i, j) == "important", i > 0, u[i - 1] == Lexer.bang { emit(i - 1, j, .keyword) }
                else { emit(i, j, .constant) }                                                // keyword values
                i = max(j, i + 1); continue
            }
            if Lexer.isDigit(c) || (c == Lexer.dot && (at(i + 1).map(Lexer.isDigit) ?? false)) {
                var j = numberEnd(i)
                while let d = at(j), Lexer.isIdentStart(d) || d == 37 { j += 1 }                // px, %, em
                emit(i, j, .constant); i = j; continue
            }
            if c == Lexer.hash {
                var j = i + 1
                while let d = at(j), Lexer.isIdent(d) { j += 1 }
                emit(i, j, .constant); i = j; continue
            }
            i += 1
        }
    }

    // MARK: Diff

    mutating func diff() {
        while i < u.count {
            let end = lineEnd(from: i)
            if starts("+++", at: i) || starts("---", at: i) || starts("diff ", at: i) || starts("index ", at: i) {
                emit(i, end, .heading)
            } else if starts("@@", at: i) {
                emit(i, end, .range)
            } else if at(i) == Lexer.plus {
                emit(i, end, .inserted)
            } else if at(i) == Lexer.dash {
                emit(i, end, .deleted)
            }
            i = end + 1
        }
    }

    // MARK: Markdown

    mutating func markdown() {
        var fence = false
        while i < u.count {
            let end = lineEnd(from: i)
            var k = i
            while k < end, Lexer.isSpace(u[k]) { k += 1 }
            if starts("```", at: k) || starts("~~~", at: k) { fence.toggle(); emit(k, end, .constant); i = end + 1; continue }
            if fence { emit(i, end, .constant); i = end + 1; continue }
            if k < end, u[k] == Lexer.hash { emit(k, end, .heading); i = end + 1; continue }
            if k < end, u[k] == Lexer.gtSign { emit(k, end, .tag); i = end + 1; continue }
            if k + 1 < end, u[k] == Lexer.dash || u[k] == Lexer.star || u[k] == Lexer.plus, Lexer.isSpace(u[k + 1]) {
                emit(k, k + 1, .entity)
            }
            var j = k
            while j < end {
                if u[j] == Lexer.bt {
                    var e = j + 1
                    while e < end, u[e] != Lexer.bt { e += 1 }
                    emit(j, min(end, e + 1), .constant); j = e + 1; continue
                }
                j += 1
            }
            i = end + 1
        }
    }

    // MARK: Shell

    static let shellKeywords: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                                             "case", "esac", "in", "function", "return", "export", "local", "readonly",
                                             "declare", "unset", "select", "time", "exit", "break", "continue", "source"]

    mutating func shell() {
        var commandNext = true
        while i < u.count {
            let c = u[i]
            if c == Lexer.nl { i += 1; commandNext = true; continue }
            if Lexer.isSpace(c) || c == Lexer.cr { i += 1; continue }
            if c == Lexer.hash, i == 0 || Lexer.isSpace(u[i - 1]) || u[i - 1] == Lexer.nl {
                let j = lineEnd(from: i); emit(i, j, .comment); i = j; continue
            }
            if c == Lexer.dq || c == Lexer.sq { i = quoted(multiline: true); commandNext = false; continue }
            if c == Lexer.dollar {
                var j = i + 1
                if at(j) == Lexer.lbrace { while let d = at(j), d != Lexer.rbrace { j += 1 }; j = min(u.count, j + 1) }
                else if at(j) == Lexer.lparen { emit(i, j + 1, .keyword); i = j + 1; commandNext = true; continue }
                else { while let d = at(j), Lexer.isIdent(d) || d == Lexer.hash || d == 63 || d == Lexer.at { j += 1 } }
                emit(i, j, .constant); i = j; commandNext = false; continue
            }
            if c == 124 || c == 38 || c == 59 {                            // | & ;
                var j = i + 1
                while let d = at(j), d == 124 || d == 38 { j += 1 }
                emit(i, j, .keyword); i = j; commandNext = true; continue
            }
            if c == Lexer.dash, commandNext == false {                     // options: -v, --force
                var j = i + 1
                while let d = at(j), Lexer.isIdent(d) || d == Lexer.dash || d == Lexer.eq { j += 1 }
                emit(i, j, .constant); i = j; continue
            }
            if Lexer.isIdentStart(c) || c == Lexer.dot || c == Lexer.slash || c == 126 {
                var j = i
                while let d = at(j), !Lexer.isSpace(d), d != Lexer.nl, d != 59, d != 124, d != 38, d != Lexer.dq,
                      d != Lexer.sq, d != Lexer.rparenGuard { j += 1 }
                let w = word(i, j)
                if Lexer.shellKeywords.contains(w) {
                    emit(i, j, .keyword)
                    commandNext = ["then", "else", "do", "if", "elif", "while", "until", "time", "!"].contains(w)
                } else if commandNext, let eq = (i..<j).first(where: { u[$0] == Lexer.eq }), eq > i {
                    emit(i, eq, .constant)                                  // NAME=value
                } else if commandNext {
                    emit(i, j, .function)
                    commandNext = w == "sudo" || w == "env" || w == "exec" || w == "nohup"
                }
                i = j; continue
            }
            if Lexer.isDigit(c) {
                let j = numberEnd(i); emit(i, j, .constant); i = j; continue
            }
            i += 1
        }
    }

    static let rparenGuard: UInt16 = 41

    // MARK: Dockerfile

    mutating func dockerfile() {
        while i < u.count {
            let end = lineEnd(from: i)
            var k = i
            while k < end, Lexer.isSpace(u[k]) { k += 1 }
            if k < end, u[k] == Lexer.hash { emit(k, end, .comment); i = end + 1; continue }
            var j = k
            while j < end, Lexer.isIdent(u[j]) { j += 1 }
            let w = word(k, j)
            if !w.isEmpty, w == w.uppercased(), w.contains(where: \.isLetter) { emit(k, j, .keyword) }
            var s = j
            while s < end {
                let c = u[s]
                if c == Lexer.dq || c == Lexer.sq {
                    var e = s + 1
                    while e < end, u[e] != c { e += 1 }
                    e = min(end, e + 1)
                    emit(s, e, .string); s = e; continue
                }
                if c == Lexer.dollar {
                    var e = s + 1
                    if e < end, u[e] == Lexer.lbrace { while e < end, u[e] != Lexer.rbrace { e += 1 }; e = min(end, e + 1) }
                    else { while e < end, Lexer.isIdent(u[e]) { e += 1 } }
                    emit(s, e, .constant); s = e; continue
                }
                s += 1
            }
            i = end + 1
        }
    }

    // MARK: Makefile

    mutating func makefile() {
        while i < u.count {
            let end = lineEnd(from: i)
            if i < end, u[i] == Lexer.hash { emit(i, end, .comment); i = end + 1; continue }
            if i < end, u[i] != Lexer.tab, !Lexer.isSpace(u[i]) {
                var j = i
                while j < end, u[j] != Lexer.colon, u[j] != Lexer.eq { j += 1 }
                if j < end, u[j] == Lexer.colon, (j + 1 >= end || u[j + 1] != Lexer.eq) {
                    emit(i, j, .function)                               // a target
                } else if j < end {
                    var ke = j
                    if ke > i, [Lexer.colon, 63, Lexer.plus].contains(u[ke - 1]) { ke -= 1 }
                    while ke > i, Lexer.isSpace(u[ke - 1]) { ke -= 1 }
                    emit(i, ke, .constant)                              // a variable
                }
            }
            var s = i
            while s < end {
                if u[s] == Lexer.dollar, s + 1 < end, u[s + 1] == Lexer.lparen || u[s + 1] == Lexer.lbrace {
                    let close: UInt16 = u[s + 1] == Lexer.lparen ? 41 : Lexer.rbrace
                    var e = s + 2
                    while e < end, u[e] != close { e += 1 }
                    e = min(end, e + 1)
                    emit(s, e, .constant); s = e; continue
                }
                if u[s] == Lexer.hash, s > i { emit(s, end, .comment); break }
                s += 1
            }
            i = end + 1
        }
    }

    // MARK: SQL

    static let sqlKeywords: Set<String> = ["select", "from", "where", "and", "or", "not", "insert", "into", "values",
        "update", "set", "delete", "create", "table", "drop", "alter", "add", "column", "index", "primary", "key",
        "foreign", "references", "join", "inner", "left", "right", "outer", "full", "on", "as", "group", "by", "order",
        "having", "limit", "offset", "distinct", "union", "all", "case", "when", "then", "else", "end", "in", "is",
        "like", "between", "exists", "with", "returning", "default", "unique", "check", "constraint", "view", "if",
        "begin", "commit", "rollback", "transaction", "asc", "desc", "cascade", "grant", "revoke", "trigger",
        "function", "procedure", "declare", "replace", "explain", "analyze", "vacuum", "pragma", "using", "over",
        "partition", "window", "filter", "conflict", "do", "nothing", "returns", "language"]
    static let sqlTypes: Set<String> = ["int", "integer", "bigint", "smallint", "text", "varchar", "char", "boolean",
        "bool", "real", "float", "double", "numeric", "decimal", "date", "time", "timestamp", "timestamptz", "json",
        "jsonb", "uuid", "blob", "serial", "bigserial"]

    mutating func sql() {
        while i < u.count {
            let c = u[i]
            if starts("--", at: i) { let j = lineEnd(from: i); emit(i, j, .comment); i = j; continue }
            if starts("/*", at: i) {
                var j = i + 2
                while j < u.count, !starts("*/", at: j) { j += 1 }
                j = min(u.count, j + 2)
                emit(i, j, .comment); i = j; continue
            }
            if c == Lexer.sq { i = quoted(multiline: true); continue }
            if Lexer.isDigit(c) { let j = numberEnd(i); emit(i, j, .constant); i = j; continue }
            if Lexer.isIdentStart(c) {
                var j = i
                while let d = at(j), Lexer.isIdent(d) { j += 1 }
                let w = word(i, j).lowercased()
                if Lexer.sqlKeywords.contains(w) { emit(i, j, .keyword) }
                else if ["null", "true", "false"].contains(w) || Lexer.sqlTypes.contains(w) { emit(i, j, .constant) }
                else if nextSolid(j) == Lexer.lparen { emit(i, j, .function) }
                i = j; continue
            }
            i += 1
        }
    }
}

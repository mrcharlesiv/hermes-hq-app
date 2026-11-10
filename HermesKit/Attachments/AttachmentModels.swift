// Value types for photos and files (docs/spec/1x-attachments.md §6.1, §7.2, §7.5, §7.7): what sits in a composer
// draft, what a message shows, what a reply's markdown links to, and an `image_generate` result. Pure and Sendable.

import Foundation

// MARK: - Drafts (the composer's tray)

/// One photo or file in a chat's draft, from the moment it is picked until its message is sent (spec §6.1).
nonisolated struct DraftAttachment: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Codable, Sendable { case image, file, link }

    enum Upload: Hashable, Sendable, Codable {
        /// Being imported / normalised on the phone.
        case preparing(fraction: Double?)
        /// Ready; the upload has not started (offline, or queued behind another).
        case waiting
        case uploading(sent: Int64, total: Int64)
        /// On the gateway: its path and the staging folder it sits in.
        case uploaded(path: String, folder: String)
        case failed(reason: String, retryable: Bool)
    }

    /// UUID; also the local staging folder's name.
    let id: String
    var kind: Kind
    /// The safe name, as uploaded.
    var name: String
    /// "<id>/<name>", relative to the account's staging root.
    var localFile: String
    var byteSize: Int64
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// The prepared file's UTType identifier.
    var typeIdentifier: String
    var upload: Upload
    /// A link's `@url:` ref line (L390); nil for photos and files. Optional so older stashes decode.
    var refText: String? = nil

    var isLink: Bool { kind == .link }

    var isPreparing: Bool { if case .preparing = upload { return true } else { return false } }
    var isUploaded: Bool { if case .uploaded = upload { return true } else { return false } }
    var gatewayPath: String? { if case .uploaded(let path, _) = upload { return path } else { return nil } }
    var stagingFolder: String? { if case .uploaded(_, let folder) = upload { return folder } else { return nil } }
    var failure: (reason: String, retryable: Bool)? {
        if case .failed(let reason, let retryable) = upload { return (reason, retryable) } else { return nil }
    }
    /// Whether the failed tile offers Try Again: a final refusal (too big, a bad name, refused) fails the same way
    /// again; "no folder for uploads" is final too, but the gateway's owner can add the folder meanwhile.
    var offersRetry: Bool {
        guard let failure else { return false }
        return failure.retryable || failure.reason == AttachmentUploadError.noFolder.reason
    }

    /// Picked audio waits for Send (the voice stream transcribes it once, spec §13.4); everything else uploads at once.
    var defersUpload: Bool { kind == .file && MediaKinds.kind(ofName: name) == .audio }
}

/// A chat's draft: what is typed and what is attached (spec §6.6 drafts store).
nonisolated struct ChatDraft: Hashable, Sendable, Codable {
    var text: String = ""
    var attachments: [DraftAttachment] = []
    var updatedAt: Double = 0

    var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}

// MARK: - Messages (bubbles)

/// A photo or file shown in a message (spec §7.2).
nonisolated struct MessageAttachment: Hashable, Sendable {
    enum Kind: UInt8, Sendable { case image, file, folder, link }

    enum Source: Hashable, Sendable {
        /// `@image:` / `@file:` / `MEDIA:` path (absolute, or relative to the session's working folder).
        case gateway(path: String)
        /// A decoded `data:` part; its bytes are in the inline media store under this key.
        case inline(mediaKey: String)
        /// Your send from this phone, before the media cache holds the uploaded copy.
        case local(draftId: String)
        /// An https image (public internet only, no cookies).
        case remote(URL)
        /// A known image with no bytes we can show ("Photo too large to load").
        case tooLarge
    }

    var kind: Kind
    var source: Source
    /// Last path component; "Photo" when there is none.
    var name: String
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var byteSize: Int64? = nil
    /// For `.local`: the gateway path it was uploaded to, once known (what the cache keeps, never the local path).
    var uploadedPath: String? = nil

    var isImage: Bool { kind == .image }

    /// The gateway path behind this attachment, if it has one.
    var gatewayPath: String? {
        switch source {
        case .gateway(let path): return path
        case .local: return uploadedPath
        default: return nil
        }
    }

    /// What a reply picture's learnt pixel size is kept under (`ChatMediaSnapshot.replySizes`).
    var sizeKey: String? {
        switch source {
        case .gateway(let path): return path
        case .remote(let url): return url.absoluteString
        case .inline(let key): return key
        default: return nil
        }
    }

    /// The same attachment as the transcript cache keeps it: `.local` becomes its gateway path, or nil when the upload
    /// never finished (spec §7.2: no local paths survive into the cache).
    var cacheable: MessageAttachment? {
        guard case .local = source else { return self }
        guard let path = uploadedPath else { return nil }
        var copy = self
        copy.source = .gateway(path: path)
        copy.uploadedPath = nil
        return copy
    }
}

// MARK: - Reply media (markdown)

/// One media item a reply links to (`MEDIA:` → `#media:`, `![alt](src)`, a file-path link; spec §7.5).
nonisolated struct MediaRef: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case image, video, audio, file }
    var kind: Kind
    var attachment: MessageAttachment
    /// VoiceOver label (an image's alt text, else its name).
    var label: String
}

// MARK: - image_generate

/// The image an `image_generate` call made (spec §7.7; V:lib/generated-images.ts:51-80).
nonisolated struct GeneratedImageInfo: Hashable, Sendable {
    enum Aspect: String, Hashable, Sendable { case landscape, square, portrait }
    /// A gateway path or an https URL; nil while the tool runs (or when it never produced one).
    var source: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var aspect: Aspect
    var success: Bool
    /// Every path/URL the reply may repeat for this image (`host_image`, `image`, `agent_visible_image`; on a container
    /// or SSH backend the agent's own path differs from the gateway's), so the prose drops them (spec §7.7).
    var echoes: Set<String> = []

    /// Width ÷ height for the frame: the result's pixel size when known, else the requested aspect.
    var ratio: Double {
        if let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 { return Double(w) / Double(h) }
        switch aspect {
        case .landscape: return 16.0 / 9.0
        case .square: return 1
        case .portrait: return 9.0 / 16.0
        }
    }

    /// The image's name for VoiceOver and "Open image: <name>".
    var name: String {
        guard let source else { return "Image" }
        if let url = URL(string: source), url.scheme != nil { return url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent }
        let last = (source as NSString).lastPathComponent
        return last.isEmpty ? "Image" : last
    }

    /// From the call's arguments and its result (an object, or a JSON string of one). Nil when the call failed or
    /// settled without an image; a running call (no result yet) gives a sourceless placeholder.
    static func from(args: [String: JSONValue], result: JSONValue?, running: Bool) -> GeneratedImageInfo? {
        let aspect = Aspect(rawValue: (args["aspect_ratio"]?.string ?? "").lowercased()) ?? .landscape
        guard let result else { return running ? GeneratedImageInfo(source: nil, aspect: aspect, success: true) : nil }
        var object = result.object
        if object == nil, let text = result.string, let parsed = try? JSONValue.parse(Data(text.utf8)) { object = parsed.object }
        guard let object else { return nil }
        if object["success"]?.bool == false { return nil }
        guard let image = (object["host_image"]?.string ?? object["image"]?.string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !image.isEmpty else { return nil }
        var info = GeneratedImageInfo(source: image, aspect: aspect, success: true)
        info.echoes = echoes(.object(object))
        if let size = object["pixel_size"]?.string {
            let parts = size.lowercased().split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { info.pixelWidth = parts[0]; info.pixelHeight = parts[1] }
        }
        return info
    }

    /// The paths/URLs a reply may repeat for this image (so prose drops them, spec §7.7 echoes).
    static func echoes(_ result: JSONValue?) -> Set<String> {
        var object = result?.object
        if object == nil, let text = result?.string, let parsed = try? JSONValue.parse(Data(text.utf8)) { object = parsed.object }
        guard let object else { return [] }
        return Set(["host_image", "image", "agent_visible_image"].compactMap { object[$0]?.string }.filter { !$0.isEmpty })
    }
}

// MARK: - Kinds by extension (spec §7.5, §7.6)

nonisolated enum MediaKinds {
    enum Kind: Hashable, Sendable { case image, video, audio, pdf, text, table, archive, folder, other }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff"]
    /// What Hermes' `image.attach` accepts (`H:hermes_cli/cli_terminal_input.py:33-36`).
    static let hermesImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "ogg", "opus", "flac", "aac", "aiff", "caf"]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "yaml", "yml", "toml", "xml", "html", "css", "js",
                                              "ts", "tsx", "jsx", "py", "swift", "go", "rs", "rb", "java", "kt", "c", "h", "cpp",
                                              "sh", "log", "ini", "env", "sql"]
    static let tableExtensions: Set<String> = ["csv", "tsv", "xls", "xlsx", "numbers"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz"]

    static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

    static func kind(ofName name: String) -> Kind {
        let e = ext(name)
        if imageExtensions.contains(e) { return .image }
        if videoExtensions.contains(e) { return .video }
        if audioExtensions.contains(e) { return .audio }
        if e == "pdf" { return .pdf }
        if tableExtensions.contains(e) { return .table }
        if textExtensions.contains(e) { return .text }
        if archiveExtensions.contains(e) { return .archive }
        return .other
    }

    /// The markdown media kind (`MEDIA:` wording and reply blocks); `.svg` and everything unknown are files.
    static func refKind(ofName name: String) -> MediaRef.Kind {
        switch kind(ofName: name) {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        default: return .file
        }
    }

    /// The row glyph (SF Symbol, spec §7.6).
    static func glyph(_ kind: Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .table: return "tablecells"
        case .archive: return "archivebox"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }

    /// "PDF", "JPEG"…: the short type word for a detail line.
    static func typeWord(_ name: String) -> String? {
        let e = ext(name)
        guard !e.isEmpty, e.count <= 8 else { return nil }
        switch e {
        case "jpg", "jpeg": return "JPEG"
        case "md", "markdown": return "Markdown"
        case "txt": return "Text"
        default: return e.uppercased()
        }
    }

    /// [mac] Mac polish 2026-11-06 #141: the kind column of the Mac's Files lists, named as the Finder names a kind.
    /// Words where the extension is no name of its own ("Log File", "Shell Script", not "LOG", "SH"); real abbreviations
    /// (SQL, JSON, PDF) as `typeWord` gives them; "Document" when nothing says.
    static func kindWord(_ name: String, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        // Review: ".env" has no extension to NSString and ".env.local" has "local", so the name says it.
        let file = (name as NSString).lastPathComponent.lowercased()
        if file == ".env" || file.hasPrefix(".env.") { return "Environment File" }
        switch ext(name) {
        case "log": return "Log File"
        case "lock": return "Lock File"
        case "env": return "Environment File"
        case "ini", "conf", "cfg": return "Settings File"
        case "sh", "bash", "zsh": return "Shell Script"
        case "py": return "Python Script"
        case "rb": return "Ruby Script"
        case "js", "mjs", "cjs": return "JavaScript"
        case "ts": return "TypeScript"
        case "swift": return "Swift Source"
        case "go": return "Go Source"
        case "rs": return "Rust Source"
        case "java": return "Java Source"
        case "kt": return "Kotlin Source"
        case "c": return "C Source"
        case "h": return "C Header"
        case "cpp", "cc", "hpp": return "C++ Source"
        case "yml": return "YAML"
        case "htm": return "HTML"
        case "tif", "tiff": return "TIFF"
        case "mov": return "QuickTime Movie"
        case "doc", "docx": return "Word Document"
        case "xls", "xlsx": return "Excel Spreadsheet"
        case "ppt", "pptx": return "PowerPoint Presentation"
        case "numbers": return "Numbers Spreadsheet"
        case "pages": return "Pages Document"
        case "key": return "Key File"   // Review: in a gateway's folder, server.key is a TLS key far more often than Keynote
        default: return typeWord(name) ?? "Document"
        }
    }

    nonisolated(unsafe) private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let sizeLock = NSLock()

    /// "PDF · 2.4 MB", "PDF" without a size, "2.4 MB" without a type.
    static func detail(name: String, bytes: Int64?) -> String {
        var parts: [String] = []
        if let word = typeWord(name) { parts.append(word) }
        if let bytes, bytes >= 0 {
            sizeLock.lock()
            parts.append(sizeFormatter.string(fromByteCount: bytes))
            sizeLock.unlock()
        }
        return parts.isEmpty ? "File" : parts.joined(separator: " · ")
    }

    /// A path's last component, unquoted ("Photo" for an image without one).
    static func name(ofPath path: String, image: Bool) -> String {
        var p = path
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        var last = (p as NSString).lastPathComponent
        // A Windows gateway's `C:\Users\…\chart.png`: the name after the last backslash.
        if last.contains("\\") { last = last.split(separator: "\\").last.map(String.init) ?? last }
        if last.isEmpty || last == "/" { return image ? "Photo" : "File" }
        return last
    }
}

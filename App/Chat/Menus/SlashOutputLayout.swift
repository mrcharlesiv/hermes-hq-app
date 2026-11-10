import UIKit

extension TextLayout {
    /// A slash command's output row (spec 1x §8.4): centred, at most 85 % of the content width, Footnote in label-2.
    /// One line: "<command> · <output>" with the command monospaced. Several lines: the command on its own line, the
    /// output under it left-aligned and monospaced with its whitespace kept (columns line up). Drawn by `ChatLineCell`.
    nonisolated static func slashOutput(command: String, output: String, gap: CGFloat, width: CGFloat, style: ChatStyle) -> RowLayout {
        let font = style.notice
        let mono = HQFont.monoFace(ofSize: font.pointSize, weight: .regular)
        let color = ChatPalette.label2
        let content = width - 2 * ChatMetrics.sideInset
        let maxWidth = floor(content * 0.85)
        let text = NSMutableAttributedString()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byWordWrapping
        let body = output.trimmingCharacters(in: .newlines)
        let multiline = body.contains("\n")
        if multiline {
            text.append(NSAttributedString(string: command + "\n", attributes: [.font: mono, .foregroundColor: color, .paragraphStyle: centered]))
            let left = NSMutableParagraphStyle()
            left.alignment = .natural
            left.lineBreakMode = .byWordWrapping
            left.paragraphSpacingBefore = 2
            // Monospaced as the command is: space-padded columns (names, numbers, usage tables) only line up in it.
            text.append(NSAttributedString(string: body, attributes: [.font: mono, .foregroundColor: color, .paragraphStyle: left]))
        } else {
            text.append(NSAttributedString(string: command, attributes: [.font: mono, .foregroundColor: color, .paragraphStyle: centered]))
            if !body.isEmpty {
                text.append(NSAttributedString(string: " · " + body, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: centered]))
            }
        }
        linkURLs(in: text, from: text.length - body.utf16.count)
        let tk = TextKitLayout(text, width: maxWidth)
        let x = ((width - maxWidth) / 2).rounded()
        return RowLayout(height: ceil(gap + 6 + tk.size.height + 6),
                         content: .line(LineLayout(text: tk, frame: CGRect(x: x, y: gap + 6, width: maxWidth, height: tk.size.height))))
    }

    /// Explicit web addresses in the output (from `start`) become tappable links (spec 1x §8.4): `.chatLink`, tint text.
    /// Only http and https; bare domains and other schemes stay text.
    nonisolated private static func linkURLs(in text: NSMutableAttributedString, from start: Int) {
        guard start >= 0, start < text.length, let detector = slashLinkDetector else { return }
        let range = NSRange(location: start, length: text.length - start)
        for match in detector.matches(in: text.string, range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            // Written out in the text, not inferred from a bare "example.com".
            let written = (text.string as NSString).substring(with: match.range).lowercased()
            guard written.hasPrefix("http://") || written.hasPrefix("https://") else { continue }
            text.addAttributes([.chatLink: url, .foregroundColor: ChatPalette.tintText], range: match.range)
        }
    }

    nonisolated private static let slashLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

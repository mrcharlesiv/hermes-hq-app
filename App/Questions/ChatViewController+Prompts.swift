import UIKit

// The chat screen's side of the prompt cells (spec 1x §4.2): taps and the countdown go to its prompts controller.

extension ChatViewController: ChatPromptCellHandling {
    func promptCard(_ id: String, tapped button: ApprovalButton) { promptsUI?.cardTapped(id, button) }
    func promptCardShowAll(_ id: String) { promptsUI?.showAll(id) }
    func promptExpiryLabel(clockKey: String, firstSeen: Date) -> String { promptsUI?.expiryLabel(firstSeen: firstSeen) ?? "" }
    func draftCard(_ draft: DraftCardRow, tapped button: DraftButton) { draftCardTapped(draft, button) }   // [drafts]
    func draftCardToggle(rowId: String) { chatCellToggle(rowId: rowId) }
    /// The conversation a draft answers, in a sheet (the step sheet's blocks, on the app's glass): every message the
    /// bot attached, whole, each under who wrote it and when; a long press copies one. A conversation opens at its
    /// newest message (scroll up to read back); one message opens at its top.
    func draftCardThread(_ draft: DraftCardRow) {
        let thread = draft.draft.thread
        guard !thread.isEmpty else { return }
        let blocks = thread.map { ChatBlocksViewController.Block(label: [$0.from, $0.when].filter { !$0.isEmpty }.joined(separator: " · "), text: $0.text, mono: false) }
        let page = ChatBlocksViewController(heading: nil, blocks: blocks)
        page.view.accessibilityIdentifier = "draft.thread.sheet"
        present(ChatSheet.wrap(page, title: thread.count == 1 ? "Previous Message" : "Conversation"), animated: true)
        guard thread.count > 1 else { return }
        // Once the sheet has its size (it is still rising): the newest message, at the bottom.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak page] in
            guard let scroll = page?.view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
            scroll.layoutIfNeeded()
            let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, bottom)), animated: false)
        }
    }
}

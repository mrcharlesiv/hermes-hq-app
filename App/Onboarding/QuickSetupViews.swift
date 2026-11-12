// [onboarding] The Mac guide and the Linux-or-server guide (docs/spec/3x-onboarding.md §5.5–§5.7; `quickSetup`,
// `W:src/connection-guide.ts:103-142`): the same three screens in each one's own words. The commands are text for the
// person to type on their own computer; the app never runs anything.

import SwiftUI

/// Step 1: get the setup command onto the computer (Copy, or the share sheet).
struct QuickSetupCommandView: View {
    let kind: OnboardingCopy.QuickKind
    let reach: SetupReach
    let go: (OnboardingStep) -> Void
    @State private var feedback: GuideFeedback

    init(kind: OnboardingCopy.QuickKind, actions: GuideActions, reach: SetupReach = SetupReach(), go: @escaping (OnboardingStep) -> Void) {
        self.kind = kind; self.reach = reach; self.go = go
        _feedback = State(initialValue: GuideFeedback(kind == .mac ? .connect : .connectLinux, actions: actions, reach: reach))
    }

    var body: some View {
        let copy = OnboardingCopy.quick(kind, tailnetOnly: reach.tailnetOnly), id = "onboarding.\(kind.rawValue)-1"
        GuidePage(id: id, heading: copy.heading1) {
            GuideParagraph(copy.lead1)
            CommandCard(id: id, block: feedback.text, copyTitle: copy.copy, shareTitle: copy.share, feedback: feedback)
            GuideParagraph(copy.footnote1, font: .subheadline)
            // For the few whose device runs Tailscale: under the command it changes, not above it.
            GuideTailnetToggle(reach: reach, id: id + ".tailnet")
        } footer: {
            GuideActionButton(title: copy.next, id: id + ".next") { go(kind == .mac ? .mac2 : .linux2) }
        }
    }
}

/// Step 2: run it, key by key, with the list of problems the terminal may show.
struct QuickSetupRunView: View {
    let kind: OnboardingCopy.QuickKind
    let reach: SetupReach
    let go: (OnboardingStep) -> Void
    @State private var links: GuideLinkOpener

    init(kind: OnboardingCopy.QuickKind, actions: GuideActions, reach: SetupReach = SetupReach(), go: @escaping (OnboardingStep) -> Void) {
        self.kind = kind; self.reach = reach; self.go = go
        _links = State(initialValue: GuideLinkOpener(actions: actions))
    }

    var body: some View {
        let copy = OnboardingCopy.quick(kind, tailnetOnly: reach.tailnetOnly), id = "onboarding.\(kind.rawValue)-2"
        GuidePage(id: id, heading: copy.heading2, error: links.error) {
            GuideSteps(steps: copy.steps2)
            GuideNote(text: copy.note2)
            GuideDisclosure(title: copy.troubleTitle, id: id + ".trouble") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(copy.trouble.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.problem).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("\(id).trouble.\(index)")
                            GuideParagraph(item.fix, font: .subheadline) { links.open($0) }
                        }
                    }
                }
            }
        } footer: {
            GuideActionButton(title: copy.next, id: id + ".next") { go(kind == .mac ? .mac3 : .linux3) }
        }
    }
}

/// Step 3: scan the QR code the setup prints (it opens the app with the address filled in). [mac] On a Mac: copy the
/// address printed under it, and the button to the form is the way on.
struct QuickSetupScanView: View {
    let kind: OnboardingCopy.QuickKind
    var reach = SetupReach()
    let go: (OnboardingStep) -> Void

    var body: some View {
        let copy = OnboardingCopy.quick(kind, tailnetOnly: reach.tailnetOnly), id = "onboarding.\(kind.rawValue)-3"
        GuidePage(id: id, heading: copy.heading3) {
            GuideParagraph(copy.lead3)
            GuideSteps(steps: copy.steps3)
            GuideNote(text: copy.note3)
        } footer: {
            GuideActionButton(title: copy.typeAddress, id: id + ".type-address", prominent: DeviceWord.isMac) { go(.connect) }
        }
    }
}

// Phone Calls (Beta) › Setup & how to use: plain-language guide covering samplehost setup, how to place and steer calls
// from a chat, Voice API vs. TeXML connections, and samplehost account verification tiers.

import SwiftUI
import UIKit

struct PhoneGuideView: View {
    @State private var copiedWebhook = false

    var body: some View {
        Form {
            Section {
                guideStep(
                    number: "1",
                    title: "Add credit & get a samplehost number",
                    detail: "In portal.samplehost.com, add a few dollars of credit under Billing and buy an active voice number under Numbers › Buy Numbers."
                )
                guideStep(
                    number: "2",
                    title: "Connect your samplehost API key",
                    detail: "Create an API key under Keys & Credentials › API Keys and paste it into Settings › Voice & Calls › Phone Calls (Beta). Your key stays in this device's Keychain and is never sent to your gateway."
                )
                guideStep(
                    number: "3",
                    title: "Create your Voice API connection & AI Assistant",
                    detail: "Use Create Voice Connection and Create Assistant right in Hermes HQ. One tap configures an Outbound Voice Profile, a Voice API (Call Control) application, your number assignment, and a tuned voice assistant."
                )
                guideStep(
                    number: "4",
                    title: "Run Check my setup",
                    detail: "Tap Check my setup in Phone Calls (Beta) to confirm your key, number, Voice API connection, outbound profile, assistant, and balance all pass."
                )
            } header: {
                Text("Quick setup")
            }

            Section {
                guideRow(
                    symbol: "sparkles",
                    title: "Ask your bot in any chat",
                    detail: "Ask in plain words — for example, “Call Corner Bistro at 212 555 0142 to book a table for two at 7” or “Call me to plan my afternoon.” Your bot prepares a Call card with the goal and opening line. Nothing dials until you tap Review and Place call."
                )
                guideRow(
                    symbol: "phone.fill",
                    title: "Start a call manually",
                    detail: "Open any chat, tap ⋯ (More) › Phone Call, pick Someone else or Myself, enter the phone number and purpose, then tap Review call to check the exact opening line before dialing."
                )
                guideRow(
                    symbol: "bubble.left.and.exclamationmark.bubble.right.fill",
                    title: "Follow & steer live",
                    detail: "Watch the live transcript as they speak (a few seconds behind while samplehost streams batches). If the assistant needs a decision only you have, an orange Waiting on you card appears with tap-to-answer choices. You can also type into Tell the assistant… at any point to guide it mid-call."
                )
                guideRow(
                    symbol: "text.Append",
                    symbolFallback: "doc.text",
                    title: "Automatic chat summary",
                    detail: "When the call ends, Hermes HQ posts a summary card, any questions you answered, and the transcript back into the chat so your bot knows what happened."
                )
            } header: {
                Text("How to use Phone Calls")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use Voice API (Call Control), not TeXML")
                        .font(Font.hq(.subheadline).weight(.semibold))
                    Text("When an AI Assistant turns on telephony in samplehost, samplehost automatically creates a TeXML Application for it. Outbound calls from Hermes HQ use samplehost's Voice API (POST /v2/calls), which rejects TeXML and SIP connections with “connection_id (Call Control App ID) is either invalid or does not exist.”")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                    Text("Use Create Voice Connection in Settings › Voice & Calls › Phone Calls (Beta) so Hermes HQ sets up a real Voice API application and links your number to it. If you create one manually in the samplehost portal, go to Voice › Programmable Voice › Voice API Applications (not TeXML), attach an enabled Outbound Voice Profile allowing your country, assign your phone number to it, and set an https:// webhook URL.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
                .padding(.vertical, 2)

                Button {
                    UIPasteboard.general.string = PhoneLimits.voiceWebhookURL
                    Haptics.play(.success)
                    copiedWebhook = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(copiedWebhook ? "Copied webhook URL" : "Copy no-server webhook URL")
                            Text(PhoneLimits.voiceWebhookURL)
                                .font(Font.hq(.caption))
                                .foregroundStyle(Color.hqLabel2)
                        }
                        Spacer()
                        Image(systemName: copiedWebhook ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(copiedWebhook ? Color.hqGreen : Color.hqTintText)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("phone.guide.copy-webhook")
            } header: {
                Text("Troubleshooting connection_id & TeXML errors")
            } footer: {
                Text("Hermes HQ reads call status, events, and transcripts directly from samplehost with your API key, so no webhook server is needed.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why a new samplehost account may only call your Verified Number")
                        .font(Font.hq(.subheadline).weight(.semibold))
                    Text("Brand-new samplehost accounts start at Level 1 verification. At Level 1, samplehost often restricts outbound calls to numbers you have verified under Verified Numbers in the samplehost portal, caps hourly call volume, or plays a brief automated-call notice.")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                    Text("To call businesses and other people freely, complete Level 2 verification in the samplehost portal and make sure your Outbound Voice Profile lists the destination country (such as US).")
                        .font(Font.hq(.footnote))
                        .foregroundStyle(Color.hqLabel2)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Calling outside your own number")
            }
        }
        .hqGroupedPage()
        .accessibilityIdentifier("phone.guide")
    }

    private func guideStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(Font.hq(.subheadline).weight(.bold))
                .foregroundStyle(Color.hqTintText)
                .frame(minWidth: 18, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Font.hq(.subheadline).weight(.semibold))
                Text(detail)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func guideRow(symbol: String, symbolFallback: String? = nil, title: String, detail: String) -> some View {
        let resolvedSymbol = UIImage(systemName: symbol) != nil ? symbol : (symbolFallback ?? "phone")
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: resolvedSymbol)
                .font(Font.hq(.subheadline).weight(.semibold))
                .foregroundStyle(Color.hqTintText)
                .frame(minWidth: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Font.hq(.subheadline).weight(.semibold))
                Text(detail)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

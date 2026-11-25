import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Verification code AutoFill across chat, clarify, vault, and browser")
struct VerificationCodeAutoFillTests {
    @Test func detectsEmailSmsAndAuthenticatorVerificationPrompts() {
        let positives = [
            "Acme sent a 6-digit verification code to your email. Please enter it so I can finish signing in.",
            "I'm trying to log in to Example Shop — what's the SMS code they just sent?",
            "They texted a one-time code to your phone. Reply with the code to continue.",
            "Enter the 2FA code from your authenticator app.",
            "Please share the security code sent to your inbox.",
            "The site is asking for a login code (emailed to you).",
            "Can you send me the sign-in code?",
            "Waiting for the OTP sent to your email address.",
            "What is the 4-digit passcode sent via SMS?",
            "They emailed a code to verify your account — drop it here when it arrives.",
            "Please paste the authentication code so I can complete login.",
            "I need the confirmation code from your messages.",
            "What's the 6 digit code from your text?",
            "I'm logged in to the portal, but billing now asks for a verification code — can you share it?",
        ]
        for text in positives {
            #expect(VerificationCodePrompt.asksForCode(text), "Expected match for: \(text)")
        }
    }

    @Test func ignoresNonOtpCodeDiscussionsAndCompletedLogins() {
        let negatives = [
            "Can you send me the source code for that file?",
            "The server returned HTTP status code 502. Should I retry?",
            "What's the zip code for the delivery address?",
            "Do you have a promo code or discount code to apply at checkout?",
            "Please share the error code from the terminal output.",
            "Scan the QR code on the receipt?",
            "Here is the hex color code: #FFAA00. Want me to change it?",
            "The process exited with exit code 1. Want me to inspect the logs?",
            "Can you review this code snippet before I push?",
            "What's the country code for that phone number?",
            "I entered the verification code and I'm logged in now. Here are your recent orders.",
            "Verification succeeded and I signed in successfully to Example Shop.",
            "Good morning! How can I help you today?",
            "",
        ]
        for text in negatives {
            #expect(!VerificationCodePrompt.asksForCode(text), "Unexpected match for: \(text)")
        }
    }

    @Test func activeMessageIdTracksOnlyUnansweredAssistantCodePrompts() {
        let userAsk = ChatMessage(id: "u1", role: .user, parts: [.text("Log into Example Shop")], timestamp: nil, rowId: 1)
        let botCode = ChatMessage(id: "a1", role: .assistant,
                                  parts: [.text("Example Shop sent a verification code to your email. Please reply with the code.")],
                                  timestamp: nil, rowId: 2)
        let userReply = ChatMessage(id: "u2", role: .user, parts: [.text("482910")], timestamp: nil, rowId: 3)
        let botDone = ChatMessage(id: "a2", role: .assistant,
                                  parts: [.text("Thanks, I entered the verification code and I'm logged in now.")],
                                  timestamp: nil, rowId: 4)

        #expect(VerificationCodePrompt.activeMessageId(in: [userAsk]) == nil)
        #expect(VerificationCodePrompt.activeMessageId(in: [userAsk, botCode]) == "a1")
        #expect(VerificationCodePrompt.activeMessageId(in: [userAsk, botCode, userReply]) == nil)
        #expect(VerificationCodePrompt.activeMessageId(in: [userAsk, botCode, userReply, botDone]) == nil)
    }

    @Test func browserKeyFieldCodeSlotKeepsQuickTypeAutofillEnabled() {
        let codeField = BrowserKeyField(slot: .code, name: "Ivy")
        #expect(codeField.textContentType == .oneTimeCode)
        #expect(codeField.autocorrectionType == .default)
        #expect(codeField.keyboardType == .asciiCapable)
    }

    @Test func questionDockUsesOneTimeCodeTextFieldForVerificationQuestions() throws {
        let otpQuestion = ClarifyQuestion(qid: "q0", question: "Enter the 6-digit verification code sent to your email",
                                          choices: nil, multiSelect: false)
        let otpPage = QuestionPageView(question: otpQuestion, stage: ClarifyStage(), last: true)
        let otpField = try #require(otpPage.answerField)
        let nativeField = try #require(otpField.codeField)
        #expect(otpField.oneTimeCode)
        #expect(nativeField.textContentType == .oneTimeCode)
        #expect(nativeField.autocorrectionType == .default)
        #expect(nativeField.keyboardType == .asciiCapable)
        #expect(otpField.textView.isHidden)

        var updated: ClarifyStage?
        var returned = false
        otpPage.onStage = { updated = $0 }
        otpPage.onReturn = { returned = true }
        nativeField.text = "842910"
        nativeField.sendActions(for: .editingChanged)
        #expect(updated?.draft == "842910")
        #expect(otpField.text == "842910")
        _ = otpPage.textFieldShouldReturn(nativeField)
        #expect(returned)

        let normalQuestion = ClarifyQuestion(qid: "q1", question: "Which branch should I deploy?", choices: nil, multiSelect: false)
        let normalPage = QuestionPageView(question: normalQuestion, stage: ClarifyStage(), last: true)
        let normalField = try #require(normalPage.answerField)
        #expect(!normalField.oneTimeCode)
        #expect(normalField.codeField == nil)
        #expect(!normalField.textView.isHidden)
        #expect(normalField.textView.textContentType == nil)
    }

    @Test func verificationCodeBannerConfiguresOneTimeCodeFieldAndSubmits() {
        let banner = VerificationCodeBanner(messageId: "a1")
        #expect(banner.codeField.textContentType == .oneTimeCode)
        #expect(banner.codeField.autocorrectionType == .default)
        #expect(banner.codeField.keyboardType == .asciiCapable)
        #expect(banner.codeField.returnKeyType == .send)
        #expect(!banner.isSendEnabled)

        var sent: [String] = []
        var dismissed = false
        banner.onSend = { sent.append($0) }
        banner.onDismiss = { dismissed = true }

        banner.codeField.text = "  482910 \n"
        banner.codeField.sendActions(for: .editingChanged)
        #expect(banner.isSendEnabled)

        _ = banner.textFieldShouldReturn(banner.codeField)
        #expect(sent == ["482910"])
        #expect(banner.codeField.text?.isEmpty == true)
        #expect(!banner.isSendEnabled)
        #expect(!dismissed)
    }

    @Test func composerOneTimeCodeHintAppliesOnlyWhileEmpty() {
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        #expect(composer.textView.textContentType == nil)
        composer.setOneTimeCodeHint(true)
        #expect(composer.textView.textContentType == UITextContentType.oneTimeCode)
        composer.text = "Use my other email"
        #expect(composer.textView.textContentType == nil)
        composer.text = ""
        #expect(composer.textView.textContentType == UITextContentType.oneTimeCode)
        composer.setOneTimeCodeHint(false)
        #expect(composer.textView.textContentType == nil)
    }
}

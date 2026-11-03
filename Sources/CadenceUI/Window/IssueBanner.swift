// A write that did not land, said once at the top of the window (docs/SPEC.md section 4.6): what happened, that the
// text is kept, and a way to dismiss it. The next write that succeeds clears it.
import SwiftUI

struct IssueBanner: View {
    let issue: StoreFailure
    let canCopy: Bool
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CadenceSpace.s12) {
            VStack(alignment: .leading, spacing: CadenceSpace.s2) {
                Text(issue.summary.hasSuffix(".") ? issue.summary : issue.summary + ".")
                    .cadenceType(CadenceType.sentence)
                    .foregroundStyle(CadenceColor.ink.color)
                Text(canCopy ? String(localized: "Not saved. Your text is kept.") : String(localized: "Not saved. \(issue.detail)"))
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink2.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if canCopy { Button("Copy my text", action: copy) }
            Button("Dismiss", action: dismiss)
        }
        .padding(CadenceSpace.s12)
        .background(CadenceColor.card.color, in: RoundedRectangle(cornerRadius: CadenceRadius.tile, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Not saved. \(issue.summary)")
    }
}

/// "Notifications are off" (section 4.6): reminders cannot reach you, and the menu-bar mark still shows a wrap-up.
struct NotificationsOffBanner: View {
    static let settings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CadenceSpace.s12) {
            VStack(alignment: .leading, spacing: CadenceSpace.s2) {
                Text("Notifications are off for Cadence.")
                    .cadenceType(CadenceType.sentence)
                    .foregroundStyle(CadenceColor.ink.color)
                Text("The menu-bar mark still shows when a wrap-up is due.")
                    .cadenceType(CadenceType.comparison)
                    .foregroundStyle(CadenceColor.ink2.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Open System Settings") { NSWorkspace.shared.open(Self.settings) }
            Button("Not now", action: dismiss)
        }
        .padding(CadenceSpace.s12)
        .background(CadenceColor.card.color, in: RoundedRectangle(cornerRadius: CadenceRadius.tile, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications are off for Cadence.")
    }
}

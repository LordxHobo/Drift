import SwiftUI
import UIKit

/// Popups that must show above everything in Drift (sheets, the full-screen player): "listen together?"
/// and why joining didn't work. They live in their own window on top, so nothing can hide them.
@MainActor
final class InviteOverlay {
    static let shared = InviteOverlay()
    private var window: UIWindow?

    private init() {}

    /// "mira invited you to listen to … together": Join or Decline.
    func ask(_ invite: JamInvite) {
        let message = invite.title.isEmpty
            ? "\(invite.fromName) invited you to listen together."
            : "\(invite.fromName) invited you to listen to “\(invite.title)” by \(invite.artist) together."
        show(OverlayCard(title: "Listen together?", message: message, buttons: [
            .init(title: "Decline", primary: false) { JamInvites.shared.decline(invite) },
            .init(title: "Join", primary: true) { Task { await JamInvites.shared.accept(invite) } },
        ]))
    }

    /// A message with an OK button.
    func tell(_ title: String, _ message: String) {
        show(OverlayCard(title: title, message: message, buttons: [
            .init(title: "OK", primary: true) { InviteOverlay.shared.hide() },
        ]))
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }

    private func show(_ card: OverlayCard) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let host = UIHostingController(rootView: card)
        host.view.backgroundColor = .clear
        let w = window ?? UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        // Same light/dark choice as the rest of Drift.
        w.overrideUserInterfaceStyle = scene.windows.first(where: { $0 !== w })?.overrideUserInterfaceStyle ?? .unspecified
        w.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }
}

/// The popup: dimmed background, a card with a title, a message and buttons.
private struct OverlayCard: View {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let primary: Bool
        let run: @MainActor () -> Void
    }

    let title: String
    let message: String
    let buttons: [Action]
    @State private var shown = false
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.45 : 0).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 19, weight: .heavy))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ForEach(buttons) { b in
                        Button {
                            b.run()
                        } label: {
                            Text(b.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(b.primary ? Theme.onAccent : Theme.text)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(b.primary ? accent : Theme.surface2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
            .padding(24)
            .scaleEffect(shown ? 1 : 0.92)
            .opacity(shown ? 1 : 0)
        }
        .foregroundStyle(Theme.text)
        .onAppear {
            withAnimation(.spring(duration: 0.3)) { shown = true }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

import CryptoKit
import SwiftUI

/// Linking Drift on a computer to this phone's profile, so both share one library.
///
/// The computer shows a code and posts it (with its public key) to pairings/{code}. The phone looks it
/// up, and answers with its sign-in, encrypted so only that computer can read it (P-256 key agreement,
/// HKDF-SHA256, AES-GCM). The computer deletes the code once it's linked.
@MainActor
enum ComputerLink {
    struct Request {
        let code: String
        let device: String
        let key: P256.KeyAgreement.PublicKey
    }

    enum LinkError: LocalizedError {
        case notFound, expired, used, noProfile

        var errorDescription: String? {
            switch self {
            case .notFound: return "That code wasn't found. Check it against the one on your computer."
            case .expired: return "That code has expired. Make a new one on your computer."
            case .used: return "That code was already used. Make a new one on your computer."
            case .noProfile: return "Create a Drift profile first (Settings → Profile). Your library syncs through it."
            }
        }
    }

    private static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Upper-case, without the dash or anything that can't be in a code.
    static func normalize(_ s: String) -> String {
        String(s.uppercased().filter { alphabet.contains($0) }.prefix(8))
    }

    static func lookUp(_ raw: String) async throws -> Request {
        let code = normalize(raw)
        guard code.count == 8 else { throw LinkError.notFound }
        guard SocialStore.shared.me != nil else { throw LinkError.noProfile }
        guard let doc = try await Firestore.get("pairings/\(code)"),
              let f = doc["fields"] as? [String: Any] else { throw LinkError.notFound }
        if FV.data(f, "box") != nil { throw LinkError.used }
        let created = Double(FV.int(f, "createdAt") ?? 0) / 1000
        if Date().timeIntervalSince1970 - created > 10 * 60 { throw LinkError.expired }
        guard let keyData = FV.data(f, "desktopKey"),
              let key = try? P256.KeyAgreement.PublicKey(x963Representation: keyData) else { throw LinkError.notFound }
        return Request(code: code, device: FV.string(f, "device") ?? "your computer", key: key)
    }

    static func link(_ r: Request) async throws {
        guard SocialStore.shared.me != nil else { throw LinkError.noProfile }
        let session = try await FirebaseAuth.shared.currentSession()
        let mine = P256.KeyAgreement.PrivateKey()
        let secret = try mine.sharedSecretFromKeyAgreement(with: r.key)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(r.code.utf8),
                                                 sharedInfo: Data("drift-pairing-v1".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(session), using: key)
        guard let box = sealed.combined else { throw LinkError.notFound }
        try await Firestore.patch("pairings/\(r.code)",
                                  fields: ["phoneKey": FV.bytes(mine.publicKey.x963Representation), "box": FV.bytes(box)],
                                  mask: ["phoneKey", "box"])
        // Push anything not yet synced, so the computer gets everything straight away.
        LibrarySync.shared.localChanged()
    }
}

/// Settings → Link a computer: type the code Drift shows on the computer.
struct LinkComputerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var request: ComputerLink.Request?
    @State private var working = false
    @State private var error: String?
    @State private var done = false
    @FocusState private var focused: Bool
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if done {
                    finished
                } else if let request {
                    confirm(request)
                } else {
                    enterCode
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Link a computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(done ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private var enterCode: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Drift on your computer, go to Settings and choose Link your phone. Type the code it shows.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.text2)
            TextField("ABCD-EFGH", text: Binding(
                get: { code },
                set: { new in
                    let c = ComputerLink.normalize(new)
                    code = c.count > 4 ? "\(c.prefix(4))-\(c.dropFirst(4))" : c
                    error = nil
                }))
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .multilineTextAlignment(.center)
                .focused($focused)
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onAppear { focused = true }
                .submitLabel(.next)
                .onSubmit(lookUp)
            if let error { errorText(error) }
            Button(action: lookUp) {
                HStack {
                    if working { ProgressView().tint(Theme.onAccent) }
                    Text("Next")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(ComputerLink.normalize(code).count != 8 || working)
            .opacity(ComputerLink.normalize(code).count == 8 ? 1 : 0.5)
        }
    }

    private func confirm(_ r: ComputerLink.Request) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 40))
                .foregroundStyle(accent)
            Text("Link \(r.device)?")
                .font(.system(size: 22, weight: .heavy))
            Text("It gets your Drift profile and library: playlists, albums, liked songs and followed artists, kept in sync both ways. Only link computers you use.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
            if let error { errorText(error) }
            Button {
                working = true
                error = nil
                Task {
                    do {
                        try await ComputerLink.link(r)
                        done = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } catch {
                        self.error = error.localizedDescription
                    }
                    working = false
                }
            } label: {
                HStack {
                    if working { ProgressView().tint(Theme.onAccent) }
                    Text("Link")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(working)
            Button("Use a different code") {
                request = nil
                code = ""
                error = nil
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(accent)
            Text("Linked")
                .font(.system(size: 22, weight: .heavy))
            Text("Your library shows up on the computer in a few seconds. To unlink, use Settings on the computer.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
        }
    }

    private func errorText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hex: 0xFF6B5B))
    }

    private func lookUp() {
        guard ComputerLink.normalize(code).count == 8, !working else { return }
        working = true
        error = nil
        Task {
            do {
                request = try await ComputerLink.lookUp(code)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

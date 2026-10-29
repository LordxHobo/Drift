import SwiftUI

/// "What's new in Drift", shown once after an update.
struct PatchNotesSheet: View {
    let entries: [PatchNotes.Entry]
    @Environment(\.dismiss) private var dismiss
    private var accent: Color { AppSettings.shared.accent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(entries) { e in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(e.title)
                                .font(.system(size: 19, weight: .heavy))
                            Text([PatchNotes.build(of: e), PatchNotes.dateText(e.date)].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.muted)
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(e.notes, id: \.self) { n in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Circle().fill(accent).frame(width: 6, height: 6)
                                        Text(n.text)
                                            .font(.system(size: 15))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("What's new in Drift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Got it") { dismiss() }.fontWeight(.bold) }
            }
        }
        .tint(accent)
        .presentationDetents([.medium, .large])
        .onDisappear { PatchNotes.markSeen() }
    }
}

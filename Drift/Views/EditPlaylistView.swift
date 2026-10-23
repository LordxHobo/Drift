import SwiftUI
import PhotosUI

/// Rename a playlist and change its cover: automatic artwork, a color with an icon, or a photo.
struct EditPlaylistView: View {
    let playlist: Playlist
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var style: Playlist.CoverStyle
    @State private var colorIndex: Int
    @State private var symbol: String
    @State private var pickedItem: PhotosPickerItem?
    @State private var newPhoto: UIImage?
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    private var library: Library { .shared }
    private var accent: Color { AppSettings.shared.accent }

    static let symbols = [
        "music.note.list", "music.note", "heart.fill", "star.fill", "flame.fill", "bolt.fill",
        "car.fill", "moon.stars.fill", "sun.max.fill", "cloud.rain.fill", "leaf.fill", "headphones",
        "guitars.fill", "pianokeys", "music.mic", "figure.run", "dumbbell.fill", "party.popper.fill",
        "sparkles", "airplane", "beach.umbrella.fill", "gamecontroller.fill", "book.fill", "cup.and.saucer.fill",
    ]

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
        _style = State(initialValue: playlist.style)
        _colorIndex = State(initialValue: playlist.colorIndex)
        _symbol = State(initialValue: playlist.symbol)
    }

    private var previewPhoto: UIImage? {
        guard style == .photo else { return nil }
        return newPhoto ?? library.coverImage(playlist)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    PlaylistCover(tracks: playlist.tracks, size: 180, color: Theme.tile(colorIndex),
                                  symbol: symbol, corner: 6, forceTile: style == .color, photo: previewPhoto)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
                        .frame(maxWidth: .infinity)
                        .animation(.easeOut(duration: 0.2), value: style)

                    VStack(alignment: .leading, spacing: 8) {
                        label("Name")
                        TextField("Playlist name", text: $name)
                            .font(.system(size: 17, weight: .semibold))
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .padding(.horizontal, 12)
                            .frame(height: 48)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        label("Cover")
                        HStack(spacing: 4) {
                            styleButton("Songs", .auto)
                            styleButton("Color", .color)
                            styleButton("Photo", .photo)
                        }
                        .padding(4)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        switch style {
                        case .auto:
                            Text("Uses the artwork of the first songs in the playlist.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        case .color:
                            colorPicker
                            symbolPicker
                        case .photo:
                            PhotosPicker(selection: $pickedItem, matching: .images) {
                                Label(previewPhoto == nil ? "Choose a photo" : "Choose another photo",
                                      systemImage: "photo.on.rectangle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            Text("The photo is cropped to a square.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                    }

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Text("Delete playlist")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFF6B5B))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .foregroundStyle(Theme.text)
            .navigationTitle("Edit playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.bold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        newPhoto = image
                    }
                }
            }
            .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete playlist", role: .destructive) {
                    library.deletePlaylist(playlist.id)
                    dismiss()
                }
            }
        }
        .tint(accent)
    }

    private var colorPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8), spacing: 10) {
            ForEach(Theme.tiles.indices, id: \.self) { i in
                Button {
                    colorIndex = i
                } label: {
                    Circle()
                        .fill(Theme.tile(i))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Theme.text, lineWidth: colorIndex == i ? 3 : 0).padding(-3))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(i + 1)")
                .accessibilityAddTraits(colorIndex == i ? .isSelected : [])
            }
        }
    }

    private var symbolPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(Self.symbols, id: \.self) { s in
                Button {
                    symbol = s
                } label: {
                    Image(systemName: s)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(symbol == s ? Theme.onAccent : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(symbol == s ? accent : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(symbol == s ? .isSelected : [])
            }
        }
        .padding(.top, 6)
    }

    private func styleButton(_ title: String, _ s: Playlist.CoverStyle) -> some View {
        Button {
            style = s
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(style == s ? Theme.onAccent : Color(hex: 0xD4D4D8))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(style == s ? accent : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(style == s ? .isSelected : [])
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.muted)
    }

    private func save() {
        library.updatePlaylist(playlist.id, name: name, style: style, colorIndex: colorIndex,
                               symbol: symbol, photo: style == .photo ? newPhoto : nil)
        dismiss()
    }
}

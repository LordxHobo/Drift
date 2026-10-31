import SwiftUI

/// Side drawer opened from your photo on Home (or a swipe from the left edge):
/// your profile, notifications, friends and settings.
struct ProfileDrawer: View {
    @Binding var isOpen: Bool
    /// Opens a page in the current tab.
    var open: (Route) -> Void
    @GestureState private var drag: CGFloat = 0
    private var social: SocialStore { .shared }
    private var notifications: NotificationStore { .shared }
    private var accent: Color { AppSettings.shared.accent }

    static let background = Theme.dynamic(dark: 0x141417, light: 0xF7F7F8)

    var body: some View {
        GeometryReader { geo in
            let width = (geo.size.width * 0.73).rounded()
            let shift = isOpen ? min(0, drag) : -width
            let progress = max(0, 1 + shift / width)
            ZStack(alignment: .leading) {
                Color.black.opacity((DriftGlass.isOn ? 0.35 : 0.55) * progress)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHidden(!isOpen)

                panel
                    .frame(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background {
                        if DriftGlass.isOn {
                            // Floating glass panel, slightly in from the screen edges.
                            Color.clear
                                .driftGlass(in: RoundedRectangle(cornerRadius: 34, style: .continuous), clear: false)
                                .padding(.vertical, 8)
                                .padding(.leading, 8)
                                .ignoresSafeArea()
                        } else {
                            Self.background.ignoresSafeArea()
                        }
                    }
                    .shadow(color: .black.opacity(isOpen && !DriftGlass.isOn ? 0.45 : 0), radius: 24, x: 8)
                    .offset(x: shift)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityHidden(!isOpen)
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .updating($drag) { v, s, _ in s = v.translation.width }
                    .onEnded { v in
                        if v.translation.width < -width * 0.3 || v.predictedEndTranslation.width < -width * 0.6 {
                            close()
                        }
                    },
                including: isOpen ? .all : .none
            )
        }
        .allowsHitTesting(isOpen)
        .animation(.easeOut(duration: 0.25), value: isOpen)
        .animation(.interactiveSpring(), value: drag)
        .onChange(of: isOpen) { _, open in
            if open { Task { await social.refreshFollowing() } }
        }
    }

    private func close() { isOpen = false }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 20)
                .padding(.bottom, 18)
            Divider().overlay(Theme.line.opacity(0.5))

            if social.me != nil {
                item("Notifications", icon: "bell", route: .notifications) {
                    let unread = notifications.unreadCount
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(accent, in: Capsule())
                    }
                }
                item("Friends", icon: "person.2", route: .friends) {
                    let listening = social.following.filter(\.isListeningNow).count
                    if listening > 0 {
                        Text("\(listening) listening")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent)
                    }
                }
            } else {
                item("Notifications", icon: "bell", route: .notifications) {
                    if notifications.unreadCount > 0 {
                        Circle().fill(accent).frame(width: 9, height: 9)
                    }
                }
            }
            item("Listening stats", icon: "chart.bar", route: .stats) { EmptyView() }

            Spacer(minLength: 0)
            Divider().overlay(Theme.line.opacity(0.5))
            item("Settings", icon: "gearshape", route: .settings) { EmptyView() }
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 22)
        .padding(.leading, DriftGlass.isOn ? 8 : 0)
        .foregroundStyle(Theme.text)
    }

    @ViewBuilder private var header: some View {
        if let me = social.me {
            Button {
                open(.user(me))
            } label: {
                HStack(spacing: 12) {
                    UserAvatar(data: me.avatar, name: me.name, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(me.name)
                            .font(.system(size: 18, weight: .heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("View profile")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(me.name), view profile")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                UserAvatar(data: nil, name: "?", size: 52)
                Text("Create a profile to follow friends and share what you play.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                Button {
                    close()
                    social.showOnboarding = true
                } label: {
                    Text("Create profile")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 40)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func item<Trailing: View>(_ title: String, icon: String, route: Route,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        Button {
            open(route)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 26)
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 4)
                trailing()
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

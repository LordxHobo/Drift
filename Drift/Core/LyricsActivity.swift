import ActivityKit
import UIKit

/// Shows the current lyric line as a Live Activity: lock screen, Dynamic Island and,
/// from iOS 26, the CarPlay screen.
///
/// iOS only lets an app *start* a Live Activity while it's open on screen, so the activity is
/// started when playback begins (or when Drift comes to the foreground) and then kept updated
/// in the background across songs.
@MainActor
final class LyricsActivity {
    static let shared = LyricsActivity()

    private typealias State = LyricsActivityAttributes.ContentState

    private var activity: Activity<LyricsActivityAttributes>?
    private var track: Track?
    private var lines: [LyricLine] = []
    private var kind = "none"
    private var lineIndex = -2
    private var isPlaying = false
    private var chapterTitle = ""
    private var nextChapterTitle = ""
    private var lyricsTask: Task<Void, Never>?
    private var lastSent: State?
    private var pending: State?
    private var sending = false
    /// Wakes up exactly when the next lyric line starts (time updates can be slow while the phone is locked).
    private var nextLineTask: Task<Void, Never>?

    private init() {
        // Clean up activities left over from a previous run.
        let leftovers = Activity<LyricsActivityAttributes>.activities
        Task {
            for a in leftovers {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
        // Swiping Drift away: iOS gives only a moment, so wait (briefly) until the activity is really gone.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            LyricsActivity.endAllBlocking()
        }
    }

    private var enabled: Bool {
        AppSettings.shared.lyricsLiveActivity && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: Player hooks

    func trackChanged(_ t: Track) {
        nextLineTask?.cancel()
        track = t
        lines = []
        chapterTitle = ""
        nextChapterTitle = ""
        kind = "none"
        lineIndex = -2
        lyricsTask?.cancel()
        guard enabled else { return }
        startIfPossible()
        push()
        // Podcasts have no lyrics; the activity just shows the episode and channel.
        if t.isEpisode { return }
        lyricsTask = Task { [weak self] in
            let result = await LyricsService.shared.lyrics(for: t)
            guard let self, !Task.isCancelled, self.track?.id == t.id else { return }
            switch result {
            case .synced(let l, _):
                self.lines = l
                self.kind = "synced"
            case .plain:
                self.kind = "unsynced"
            case .notFound:
                self.kind = "none"
            }
            self.lineIndex = -2
            self.tick(Player.shared.currentTime)
            self.push()
        }
    }

    /// Podcasts show the current chapter where songs show the lyric line.
    func chapterChanged(current: String, next: String) {
        chapterTitle = current
        nextChapterTitle = next
        guard enabled else { return }
        push()
    }

    func playingChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing { scheduleNextLine(after: Player.shared.currentTime) } else { nextLineTask?.cancel() }
        guard enabled else { return }
        if playing { startIfPossible() }
        push()
    }

    func tick(_ time: Double) {
        guard activity != nil, !lines.isEmpty else { return }
        let i = Self.index(in: lines, at: time + 0.3)
        guard i != lineIndex else { return }
        lineIndex = i
        push()
        scheduleNextLine(after: time)
    }

    private func scheduleNextLine(after time: Double) {
        nextLineTask?.cancel()
        let n = lineIndex + 1
        guard isPlaying, n >= 0, n < lines.count else { return }
        let wait = max(0.05, lines[n].time - 0.3 - time)
        nextLineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.tick(Player.shared.currentTime)
        }
    }

    /// Drift came to the foreground: start the activity if something is playing.
    func appBecameActive() {
        guard enabled, track != nil else { return }
        startIfPossible()
        push()
    }

    func settingChanged() {
        if AppSettings.shared.lyricsLiveActivity {
            if let t = Player.shared.current {
                isPlaying = Player.shared.isPlaying
                trackChanged(t)
            }
        } else {
            endNow()
        }
    }

    func endNow() {
        guard let a = activity else { return }
        activity = nil
        lastSent = nil
        // Keep running long enough to finish, even if Drift is going to the background.
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        Task {
            await a.end(nil, dismissalPolicy: .immediate)
            UIApplication.shared.endBackgroundTask(bg)
        }
    }

    /// Drift went to the background with nothing playing: nothing to show on the lock screen.
    func appWentToBackground(playing: Bool) {
        if !playing { endNow() }
    }

    nonisolated static func endAllBlocking() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<LyricsActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    // MARK: Internals

    private static func index(in lines: [LyricLine], at t: Double) -> Int {
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    private func currentState() -> State? {
        guard let t = track else { return nil }
        var line = "", next = ""
        if t.isEpisode {
            line = chapterTitle
            next = nextChapterTitle
        } else if !lines.isEmpty {
            if lineIndex >= 0, lineIndex < lines.count { line = lines[lineIndex].text }
            let n = lineIndex + 1
            if n >= 0, n < lines.count { next = lines[n].text }
        }
        return State(title: t.title, artist: t.artist, line: line, nextLine: next,
                     isPlaying: isPlaying, lyricsKind: kind)
    }

    private func startIfPossible() {
        // An activity the person swiped away, or one iOS ended, can't be reused.
        if let a = activity, a.activityState == .ended || a.activityState == .dismissed {
            activity = nil
            lastSent = nil
        }
        guard activity == nil,
              UIApplication.shared.applicationState == .active,
              let state = currentState() else { return }
        do {
            activity = try Activity.request(attributes: LyricsActivityAttributes(),
                                            content: ActivityContent(state: state, staleDate: nil),
                                            pushType: nil)
            lastSent = state
        } catch {
            activity = nil
        }
    }

    /// Sends the newest state, never more than one update in flight.
    private func push() {
        guard activity != nil, let state = currentState(), state != lastSent else { return }
        pending = state
        guard !sending else { return }
        sending = true
        Task {
            while let next = self.pending, let a = self.activity {
                self.pending = nil
                await a.update(ActivityContent(state: next, staleDate: nil))
                self.lastSent = next
            }
            self.sending = false
        }
    }
}

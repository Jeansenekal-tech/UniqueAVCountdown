import Foundation
import AppKit
import Combine

/// Publishes the current time ~10× per second. Views that show live time observe this,
/// so the rundown/editor don't redraw on every tick.
final class TickClock: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

enum TimerPhase: String {
    case idle, normal, warning, critical, overtime
}

/// The core timer: rundown, transport, messages. All access is on the main thread.
final class TimerEngine: ObservableObject {
    let clock = TickClock()

    @Published var segments: [Segment] {
        didSet {
            if let id = currentID, !segments.contains(where: { $0.id == id }) {
                currentID = segments.first?.id
                clearTiming()
            } else if currentID == nil {
                currentID = segments.first?.id
            }
            persist()
        }
    }
    @Published var settings: AppSettings { didSet { persist() } }
    @Published private(set) var currentID: UUID?
    @Published private(set) var isRunning = false
    @Published private(set) var message = ""
    @Published private(set) var messageVisible = false
    @Published private(set) var messageFlashing = false
    @Published var blackout = false
    @Published var lastRemoteEvent = "—"

    private var accumulated: TimeInterval = 0
    private var runStart: Date?
    private var adjustment: TimeInterval = 0
    private var firedWarning = false, firedCritical = false, firedZero = false
    private var flashUntil: Date?
    private var sound: NSSound?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "segments"),
           let s = try? JSONDecoder().decode([Segment].self, from: data), !s.isEmpty {
            segments = s
        } else {
            segments = Segment.samples
        }
        if let data = d.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        currentID = segments.first?.id
        clock.$now.sink { [weak self] _ in self?.tick() }.store(in: &cancellables)
    }

    // MARK: - Derived state

    var currentIndex: Int? { segments.firstIndex { $0.id == currentID } }
    var current: Segment? { currentIndex.map { segments[$0] } }
    var nextSegment: Segment? {
        guard let i = currentIndex, i + 1 < segments.count else { return nil }
        return segments[i + 1]
    }

    var elapsed: TimeInterval {
        accumulated + (runStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// Total length used for progress and colours (nil = no target).
    var targetDuration: TimeInterval? {
        guard let s = current else { return nil }
        switch s.mode {
        case .countdown: return max(0, s.duration + adjustment)
        case .countUp: return s.duration > 0 ? s.duration + adjustment : nil
        case .endAtTime: return s.duration > 0 ? s.duration : nil
        }
    }

    /// Seconds remaining (negative = overtime). nil for count-up with no target.
    var remaining: TimeInterval? {
        guard let s = current else { return nil }
        switch s.mode {
        case .countdown: return s.duration + adjustment - elapsed
        case .countUp: return s.duration > 0 ? s.duration + adjustment - elapsed : nil
        case .endAtTime: return endDate(for: s).timeIntervalSinceNow + adjustment
        }
    }

    var displayText: String {
        guard let s = current else { return "--:--" }
        if s.mode == .countUp { return TimeFormat.string(elapsed) }
        let r = remaining ?? 0
        if r <= 0 {
            return settings.overtimeCountUp ? "+" + TimeFormat.string(-r) : TimeFormat.string(0)
        }
        return TimeFormat.string(r, roundUp: true)
    }

    var phase: TimerPhase {
        guard let s = current else { return .idle }
        guard let r = remaining else { return .normal }
        if r <= 0 { return .overtime }
        if r <= s.redAt { return .critical }
        if r <= s.yellowAt { return .warning }
        return .normal
    }

    /// 0…1 fraction of the segment used.
    var progress: Double {
        guard let s = current, let t = targetDuration, t > 0 else { return 0 }
        if s.mode == .endAtTime {
            return min(1, max(0, 1 - (remaining ?? 0) / t))
        }
        return min(1, max(0, elapsed / t))
    }

    var clockText: String {
        (settings.clock24h ? Self.clock24 : Self.clock12).string(from: Date())
    }

    var totalRundown: TimeInterval {
        segments.filter { $0.mode != .endAtTime }.reduce(0) { $0 + $1.duration }
    }

    private static let clock24: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let clock12: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm:ss a"; return f
    }()

    private func endDate(for s: Segment) -> Date {
        let cal = Calendar.current
        let parts = cal.dateComponents([.hour, .minute, .second], from: s.endTime)
        return cal.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0,
                        second: parts.second ?? 0, of: Date()) ?? s.endTime
    }

    // MARK: - Transport

    func start() {
        guard current != nil, !isRunning else { return }
        runStart = Date()
        isRunning = true
    }

    func pause() {
        guard isRunning else { return }
        if let rs = runStart { accumulated += Date().timeIntervalSince(rs) }
        runStart = nil
        isRunning = false
    }

    func toggle() { isRunning ? pause() : start() }

    func reset() {
        clearTiming()
        objectWillChange.send()
    }

    func go(to id: UUID, autostart: Bool = false) {
        guard segments.contains(where: { $0.id == id }) else { return }
        currentID = id
        clearTiming()
        if autostart { start() }
    }

    func go(toIndex i: Int) {
        guard segments.indices.contains(i) else { return }
        go(to: segments[i].id)
    }

    func next() {
        guard let i = currentIndex, i + 1 < segments.count else { return }
        go(to: segments[i + 1].id, autostart: isRunning && settings.startOnNext)
    }

    func previous() {
        guard let i = currentIndex, i > 0 else { return }
        go(to: segments[i - 1].id, autostart: isRunning && settings.startOnNext)
    }

    func addTime(_ seconds: TimeInterval) {
        guard let s = current else { return }
        if s.mode == .countUp && s.duration == 0 {
            accumulated = max(0, accumulated - seconds)   // nudge the count-up clock
        } else {
            adjustment += seconds
        }
        resetFlags()
        objectWillChange.send()
    }

    /// Creates an ad-hoc countdown after the current segment and starts it.
    func quickTimer(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let seg = Segment(title: "Quick timer", duration: seconds,
                          yellowAt: min(120, seconds * 0.25), redAt: min(30, seconds * 0.1))
        let insertAt = (currentIndex ?? -1) + 1
        segments.insert(seg, at: insertAt)
        go(to: seg.id, autostart: true)
    }

    private func clearTiming() {
        isRunning = false
        runStart = nil
        accumulated = 0
        adjustment = 0
        resetFlags()
    }

    private func resetFlags() {
        guard let s = current, let r = remaining else {
            firedWarning = false; firedCritical = false; firedZero = false; return
        }
        firedWarning = r <= s.yellowAt
        firedCritical = r <= s.redAt
        firedZero = r <= 0
    }

    // MARK: - Messages

    func showMessage(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        message = t
        messageVisible = true
    }

    func hideMessage() {
        messageVisible = false
        messageFlashing = false
        flashUntil = nil
    }

    func flashMessage(seconds: TimeInterval = 5) {
        guard !message.isEmpty else { return }
        messageVisible = true
        messageFlashing = true
        flashUntil = Date().addingTimeInterval(seconds)
    }

    // MARK: - Tick

    private func tick() {
        if let f = flashUntil, Date() > f {
            flashUntil = nil
            messageFlashing = false
        }
        guard isRunning, let s = current, let r = remaining else { return }
        if !firedWarning, r <= s.yellowAt {
            firedWarning = true
            if r > s.redAt, settings.soundOnWarning { play("Glass") }
        }
        if !firedCritical, r <= s.redAt {
            firedCritical = true
            if r > 0, settings.soundOnWarning { play("Ping") }
        }
        if !firedZero, r <= 0 {
            firedZero = true
            if settings.soundOnZero { play("Hero") }
            if s.autoAdvance, let i = currentIndex, i + 1 < segments.count {
                go(to: segments[i + 1].id, autostart: true)
            }
        }
    }

    private func play(_ name: String) {
        sound = NSSound(named: NSSound.Name(name))
        sound?.play()
    }

    // MARK: - Remote commands (web, OSC, MIDI)

    @discardableResult
    func perform(command raw: String, argument: String? = nil, source: String = "") -> Bool {
        let c = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let arg = argument?.trimmingCharacters(in: .whitespacesAndNewlines)
        let num = arg.flatMap { Double($0) }

        switch c {
        case "toggle", "go", "startpause", "start-pause": toggle()
        case "start", "play", "resume": start()
        case "pause", "stop": pause()
        case "reset", "restart": reset()
        case "next": next()
        case "prev", "previous", "back": previous()
        case "add", "plus": addTime(num ?? 60)
        case "sub", "subtract", "minus": addTime(-(num ?? 60))
        case "goto", "cue", "segment":
            guard let n = num else { return false }
            go(toIndex: Int(n) - 1)
        case "message", "message-show", "show-message":
            if let a = arg, !a.isEmpty, num == nil { showMessage(a) } else { showMessage(message) }
        case "message-hide", "message-clear", "hide-message", "clear", "hide":
            hideMessage()
        case "message-flash", "flash":
            if let a = arg, !a.isEmpty, num == nil { showMessage(a) }
            flashMessage()
        case "blackout":
            if let n = num { blackout = n != 0 } else { blackout.toggle() }
        case "quick":
            quickTimer(seconds: num ?? 300)
        case "layout":
            if let a = arg, !a.isEmpty { setLayout(named: a) } else { cycleLayout() }
        case "layout-timer", "video-off":
            setLayout(.timerOnly)
        case "video", "pip", "video-toggle":
            if let n = num {
                setLayout(n != 0 ? lastVideoLayout : .timerOnly)
            } else {
                toggleVideo()
            }
        default:
            return false
        }
        if !source.isEmpty {
            lastRemoteEvent = "\(source): \(c)" + (arg.map { $0.isEmpty ? "" : " \($0)" } ?? "")
        }
        return true
    }

    // MARK: - Video layout

    /// The layout "video on" returns to.
    private(set) var lastVideoLayout: VideoLayout = .videoPIP

    func setLayout(_ layout: VideoLayout) {
        if layout != .timerOnly { lastVideoLayout = layout }
        settings.videoLayout = layout
    }

    func cycleLayout() {
        let all = VideoLayout.allCases
        let i = all.firstIndex(of: settings.videoLayout) ?? 0
        setLayout(all[(i + 1) % all.count])
    }

    func toggleVideo() {
        setLayout(settings.videoLayout == .timerOnly ? lastVideoLayout : .timerOnly)
    }

    private func setLayout(named name: String) {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        if let n = Int(key), VideoLayout.allCases.indices.contains(n - 1) {
            setLayout(VideoLayout.allCases[n - 1])
        } else if let l = VideoLayout.allCases.first(where: { $0.rawValue.lowercased() == key }) {
            setLayout(l)
        }
    }

    /// State snapshot for the phone remote.
    func stateJSON() -> Data {
        let dict: [String: Any] = [
            "title": current?.title ?? "",
            "speaker": current?.speaker ?? "",
            "time": displayText,
            "phase": phase.rawValue,
            "running": isRunning,
            "progress": progress,
            "clock": clockText,
            "message": message,
            "messageVisible": messageVisible,
            "blackout": blackout,
            "index": currentIndex ?? -1,
            "next": nextSegment?.title ?? "",
            "presets": settings.cleanPresets,
            "layout": settings.videoLayout.rawValue,
            "layouts": VideoLayout.allCases.map { ["id": $0.rawValue, "label": $0.label] },
            "segments": segments.map { s -> [String: Any] in
                ["title": s.title,
                 "length": s.mode == .endAtTime ? "ends " + Self.shortTime(s.endTime)
                                                : TimeFormat.string(s.duration),
                 "mode": s.mode.rawValue]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    static func shortTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    // MARK: - Persistence & files

    private func persist() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(segments) { d.set(data, forKey: "segments") }
        if let data = try? JSONEncoder().encode(settings) { d.set(data, forKey: "settings") }
    }

    func exportRundown(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(RundownFile(segments: segments)).write(to: url, options: .atomic)
    }

    func importRundown(from url: URL) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(RundownFile.self, from: Data(contentsOf: url))
        guard !file.segments.isEmpty else { return }
        segments = file.segments
        if let first = segments.first { go(to: first.id) }
    }

    func newRundown() {
        segments = [Segment(title: "Segment 1")]
        if let first = segments.first { go(to: first.id) }
    }
}

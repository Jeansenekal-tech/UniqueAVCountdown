import Foundation

/// How a segment's timer behaves.
enum TimerMode: String, Codable, CaseIterable, Identifiable {
    case countdown      // counts down from a duration
    case countUp        // counts up from zero (optional target for colours)
    case endAtTime      // counts down to a wall-clock time (e.g. "break ends 10:30")

    var id: String { rawValue }

    var label: String {
        switch self {
        case .countdown: return "Countdown"
        case .countUp: return "Count up"
        case .endAtTime: return "End at time of day"
        }
    }

    var symbol: String {
        switch self {
        case .countdown: return "timer"
        case .countUp: return "stopwatch"
        case .endAtTime: return "clock"
        }
    }
}

/// One item in the rundown.
struct Segment: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "New segment"
    var speaker: String = ""
    var mode: TimerMode = .countdown
    var duration: TimeInterval = 300
    var endTime: Date = Date().addingTimeInterval(3600)
    var yellowAt: TimeInterval = 120
    var redAt: TimeInterval = 30
    var autoAdvance: Bool = false

    init(title: String = "New segment", speaker: String = "", mode: TimerMode = .countdown,
         duration: TimeInterval = 300, yellowAt: TimeInterval = 120, redAt: TimeInterval = 30,
         autoAdvance: Bool = false) {
        self.title = title
        self.speaker = speaker
        self.mode = mode
        self.duration = duration
        self.yellowAt = yellowAt
        self.redAt = redAt
        self.autoAdvance = autoAdvance
    }

    // Tolerant decoding so older/edited files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? "Segment"
        speaker = (try? c.decode(String.self, forKey: .speaker)) ?? ""
        mode = (try? c.decode(TimerMode.self, forKey: .mode)) ?? .countdown
        duration = (try? c.decode(TimeInterval.self, forKey: .duration)) ?? 300
        endTime = (try? c.decode(Date.self, forKey: .endTime)) ?? Date().addingTimeInterval(3600)
        yellowAt = (try? c.decode(TimeInterval.self, forKey: .yellowAt)) ?? 120
        redAt = (try? c.decode(TimeInterval.self, forKey: .redAt)) ?? 30
        autoAdvance = (try? c.decode(Bool.self, forKey: .autoAdvance)) ?? false
    }

    static var samples: [Segment] {
        [
            Segment(title: "Welcome & housekeeping", speaker: "MC", duration: 5 * 60, yellowAt: 60, redAt: 15),
            Segment(title: "Keynote", speaker: "Guest speaker", duration: 20 * 60, yellowAt: 5 * 60, redAt: 60),
            Segment(title: "Panel discussion", speaker: "Panel", duration: 30 * 60, yellowAt: 5 * 60, redAt: 60),
            Segment(title: "Q&A", duration: 10 * 60, yellowAt: 2 * 60, redAt: 30),
            Segment(title: "Tea break", duration: 15 * 60, yellowAt: 2 * 60, redAt: 30),
        ]
    }
}

/// How the video input and timer share the presenter screen.
enum VideoLayout: String, Codable, CaseIterable, Identifiable {
    case timerOnly      // no video
    case videoPIP       // video full screen, timer box in a corner
    case timerPIP       // timer full screen, video box in a corner
    case split          // video left, timer right
    case videoBar       // video above, timer strip along the bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .timerOnly: return "Timer only"
        case .videoPIP: return "Video + timer PIP"
        case .timerPIP: return "Timer + video PIP"
        case .split: return "Side by side"
        case .videoBar: return "Video + timer bar"
        }
    }

    var symbol: String {
        switch self {
        case .timerOnly: return "timer"
        case .videoPIP: return "pip"
        case .timerPIP: return "pip.fill"
        case .split: return "rectangle.split.2x1"
        case .videoBar: return "rectangle.bottomthird.inset.filled"
        }
    }
}

enum PIPCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

/// App-wide settings (persisted).
struct AppSettings: Codable, Equatable {
    // Video input layout
    var videoLayout: VideoLayout = .timerOnly
    var pipCorner: PIPCorner = .bottomRight
    var pipSize: Double = 0.34          // fraction of screen width
    var splitRatio: Double = 0.66       // video share in side-by-side
    var cropLeft: Double = 0, cropRight: Double = 0, cropTop: Double = 0, cropBottom: Double = 0
    var videoFill = false               // fill (crop to edges) instead of fit
    // Presenter display
    var showTitle = true
    var showClock = true
    var showNext = true
    var showProgress = true
    var clock24h = true
    var fontScale: Double = 1.0
    // Behaviour
    var overtimeCountUp = true
    var flashOnOvertime = true
    var soundOnWarning = true
    var soundOnZero = true
    var startOnNext = false
    var checkUpdatesOnLaunch = true
    // Remote control
    var webEnabled = true
    var webPort = 8080
    var oscEnabled = true
    var oscPort = 8000
    var midiEnabled = true
    var midiChannel = 0          // 0 = omni, 1–16
    var midiBaseNote = 60        // C3 (Apple/Ableton) / C4 (others)
    // Messages
    var messagePresets: [String] = ["Please wrap up", "5 minutes left", "1 minute left",
                                    "Time's up", "Speak up please", "Slow down"]

    /// Presets with blank lines removed (the editor keeps raw lines while typing).
    var cleanPresets: [String] {
        var seen = Set<String>()
        return messagePresets.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decode(T.self, forKey: k)) ?? def }
        videoLayout = v(.videoLayout, d.videoLayout)
        pipCorner = v(.pipCorner, d.pipCorner)
        pipSize = v(.pipSize, d.pipSize)
        splitRatio = v(.splitRatio, d.splitRatio)
        cropLeft = v(.cropLeft, d.cropLeft)
        cropRight = v(.cropRight, d.cropRight)
        cropTop = v(.cropTop, d.cropTop)
        cropBottom = v(.cropBottom, d.cropBottom)
        videoFill = v(.videoFill, d.videoFill)
        showTitle = v(.showTitle, d.showTitle)
        showClock = v(.showClock, d.showClock)
        showNext = v(.showNext, d.showNext)
        showProgress = v(.showProgress, d.showProgress)
        clock24h = v(.clock24h, d.clock24h)
        fontScale = v(.fontScale, d.fontScale)
        overtimeCountUp = v(.overtimeCountUp, d.overtimeCountUp)
        flashOnOvertime = v(.flashOnOvertime, d.flashOnOvertime)
        soundOnWarning = v(.soundOnWarning, d.soundOnWarning)
        soundOnZero = v(.soundOnZero, d.soundOnZero)
        startOnNext = v(.startOnNext, d.startOnNext)
        checkUpdatesOnLaunch = v(.checkUpdatesOnLaunch, d.checkUpdatesOnLaunch)
        webEnabled = v(.webEnabled, d.webEnabled)
        webPort = v(.webPort, d.webPort)
        oscEnabled = v(.oscEnabled, d.oscEnabled)
        oscPort = v(.oscPort, d.oscPort)
        midiEnabled = v(.midiEnabled, d.midiEnabled)
        midiChannel = v(.midiChannel, d.midiChannel)
        midiBaseNote = v(.midiBaseNote, d.midiBaseNote)
        messagePresets = v(.messagePresets, d.messagePresets)
    }
}

/// File format for saved rundowns.
struct RundownFile: Codable {
    var app = "Unique AV Countdown"
    var version = 1
    var segments: [Segment]
}

/// Commands available to MIDI notes, in order from the base note.
enum MIDIMap {
    static let commands: [(command: String, label: String)] = [
        ("toggle", "Start / Pause"),
        ("start", "Start"),
        ("pause", "Pause"),
        ("reset", "Reset"),
        ("next", "Next segment"),
        ("prev", "Previous segment"),
        ("add", "+1 minute"),
        ("sub", "−1 minute"),
        ("flash", "Flash message"),
        ("message-hide", "Hide message"),
        ("blackout", "Toggle blackout"),
        ("layout", "Next video layout"),
        ("layout-timer", "Timer only (video off)"),
    ]
}

enum TimeFormat {
    /// Formats seconds as MM:SS or H:MM:SS.
    static func string(_ t: TimeInterval, roundUp: Bool = false) -> String {
        let total = max(0, roundUp ? Int(ceil(t - 0.001)) : Int(floor(t)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

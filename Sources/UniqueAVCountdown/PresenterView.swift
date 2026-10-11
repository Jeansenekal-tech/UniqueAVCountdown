import SwiftUI

/// The big screen the presenter sees. Also used, scaled down, as the operator preview.
/// Arranges the timer and (optionally) the live video input according to the chosen layout.
struct PresenterView: View {
    @EnvironmentObject var engine: TimerEngine
    @EnvironmentObject var video: VideoInputManager
    @ObservedObject var clock: TickClock

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let unit = max(1, min(size.width / 16, size.height / 9))
            let blink = Int(clock.now.timeIntervalSince1970 * 2) % 2 == 0
            let layout = effectiveLayout

            ZStack {
                Color.black
                if !engine.blackout {
                    arrangement(layout, size: size, unit: unit)
                    if engine.messageVisible && !engine.message.isEmpty {
                        MessageBanner(text: engine.message,
                                      flashing: engine.messageFlashing,
                                      blink: blink,
                                      unit: unit,
                                      atTop: bannerAtTop(layout))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .background(Color.black)
    }

    /// Video layouts only apply when a video source is selected.
    private var effectiveLayout: VideoLayout {
        video.isActive ? engine.settings.videoLayout : .timerOnly
    }

    private func bannerAtTop(_ layout: VideoLayout) -> Bool {
        switch layout {
        case .videoBar: return true
        case .videoPIP, .timerPIP:
            return engine.settings.pipCorner == .bottomLeft || engine.settings.pipCorner == .bottomRight
        default: return false
        }
    }

    @ViewBuilder
    private func arrangement(_ layout: VideoLayout, size: CGSize, unit: CGFloat) -> some View {
        let s = engine.settings
        let pad = unit * 0.35
        let radius = unit * 0.15
        let boxW = size.width * CGFloat(min(0.6, max(0.15, s.pipSize)))
        let boxH = boxW * 9 / 16

        switch layout {
        case .timerOnly:
            TimerPanel(clock: clock)

        case .videoPIP:
            ZStack(alignment: s.pipCorner.alignment) {
                VideoBox()
                TimerPanel(clock: clock, compact: true)
                    .frame(width: boxW, height: boxH)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .overlay(RoundedRectangle(cornerRadius: radius)
                        .stroke(Self.color(for: engine.phase).opacity(0.75), lineWidth: max(2, unit * 0.05)))
                    .padding(pad)
            }

        case .timerPIP:
            ZStack(alignment: s.pipCorner.alignment) {
                TimerPanel(clock: clock, digitScale: 0.72, reserveCorner: s.pipCorner, reserveWidth: boxW + pad)
                VideoBox()
                    .frame(width: boxW, height: boxH)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .overlay(RoundedRectangle(cornerRadius: radius)
                        .stroke(Color.white.opacity(0.3), lineWidth: max(1, unit * 0.03)))
                    .padding(pad)
            }

        case .split:
            HStack(spacing: 0) {
                VideoBox()
                    .frame(width: size.width * CGFloat(min(0.85, max(0.3, s.splitRatio))))
                TimerPanel(clock: clock)
            }

        case .videoBar:
            VStack(spacing: 0) {
                VideoBox()
                TimerBar(clock: clock)
                    .frame(height: size.height * 0.2)
            }
        }
    }

    static func color(for phase: TimerPhase) -> Color {
        switch phase {
        case .idle, .normal: return .white
        case .warning: return Color(red: 1.0, green: 0.78, blue: 0.2)
        case .critical: return Color(red: 1.0, green: 0.45, blue: 0.1)
        case .overtime: return Color(red: 1.0, green: 0.22, blue: 0.22)
        }
    }

    static let overtimeRed = Color(red: 0.42, green: 0.0, blue: 0.02)
}

extension PIPCorner {
    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

// MARK: - Timer panel (scales to whatever box it's given)

struct TimerPanel: View {
    @EnvironmentObject var engine: TimerEngine
    @ObservedObject var clock: TickClock
    /// Small box: hides speaker and next segment.
    var compact = false
    var digitScale: CGFloat = 1
    /// Keeps the header/footer clear of a video PIP box in this corner.
    var reserveCorner: PIPCorner? = nil
    var reserveWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let unit = max(1, min(geo.size.width / 16, geo.size.height / 9))
            let phase = engine.phase
            let blink = Int(clock.now.timeIntervalSince1970 * 2) % 2 == 0
            let flash = phase == .overtime && engine.settings.flashOnOvertime && engine.isRunning && blink
            ZStack {
                flash ? PresenterView.overtimeRed : Color.black
                content(unit: unit, phase: phase)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func reservePadding(top: Bool) -> EdgeInsets {
        guard let c = reserveCorner, c.isTop == top else { return EdgeInsets() }
        return c.isLeft ? EdgeInsets(top: 0, leading: reserveWidth, bottom: 0, trailing: 0)
                        : EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: reserveWidth)
    }

    @ViewBuilder
    private func content(unit: CGFloat, phase: TimerPhase) -> some View {
        let s = engine.settings
        VStack(spacing: unit * 0.2) {
            HStack(alignment: .top) {
                if s.showTitle, let seg = engine.current {
                    VStack(alignment: .leading, spacing: unit * 0.06) {
                        Text(seg.title)
                            .font(.system(size: unit * (compact ? 0.75 : 0.6), weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                        if !compact && !seg.speaker.isEmpty {
                            Text(seg.speaker)
                                .font(.system(size: unit * 0.4))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: unit)
                if s.showClock {
                    Text(engine.clockText)
                        .font(.system(size: unit * (compact ? 0.65 : 0.55), weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(reservePadding(top: true))

            Spacer(minLength: 0)

            Text(engine.displayText)
                .font(.system(size: unit * 4.6 * s.fontScale * digitScale, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(PresenterView.color(for: phase))
                .lineLimit(1)
                .minimumScaleFactor(0.1)

            Spacer(minLength: 0)

            if (s.showNext && !compact) || s.showProgress {
                VStack(spacing: unit * 0.18) {
                    if s.showNext && !compact {
                        HStack {
                            if let n = engine.nextSegment {
                                (Text("NEXT   ").foregroundColor(.white.opacity(0.45))
                                 + Text(n.title).foregroundColor(.white.opacity(0.8)))
                                    .font(.system(size: unit * 0.42, weight: .medium))
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    if s.showProgress {
                        ProgressStrip(value: engine.progress, color: PresenterView.color(for: phase))
                            .frame(height: max(3, unit * (compact ? 0.2 : 0.14)))
                    }
                }
                .padding(reservePadding(top: false))
            }
        }
        .padding(unit * 0.5)
    }
}

// MARK: - Timer bar (strip under the video)

struct TimerBar: View {
    @EnvironmentObject var engine: TimerEngine
    @ObservedObject var clock: TickClock

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let s = engine.settings
            let phase = engine.phase
            let blink = Int(clock.now.timeIntervalSince1970 * 2) % 2 == 0
            let flash = phase == .overtime && s.flashOnOvertime && engine.isRunning && blink

            ZStack(alignment: .top) {
                flash ? PresenterView.overtimeRed : Color.black

                HStack(spacing: h * 0.3) {
                    VStack(alignment: .leading, spacing: h * 0.04) {
                        if s.showTitle, let seg = engine.current {
                            Text(seg.title)
                                .font(.system(size: h * 0.22, weight: .semibold))
                                .foregroundColor(.white.opacity(0.92))
                            if !seg.speaker.isEmpty {
                                Text(seg.speaker)
                                    .font(.system(size: h * 0.15))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(engine.displayText)
                        .font(.system(size: h * 0.72 * s.fontScale, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(PresenterView.color(for: phase))
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                        .layoutPriority(1)

                    VStack(alignment: .trailing, spacing: h * 0.04) {
                        if s.showClock {
                            Text(engine.clockText)
                                .font(.system(size: h * 0.2, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundColor(.white.opacity(0.7))
                        }
                        if s.showNext, let n = engine.nextSegment {
                            Text("Next: \(n.title)")
                                .font(.system(size: h * 0.14))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, h * 0.25)
                .frame(maxHeight: .infinity)

                if s.showProgress {
                    ProgressStrip(value: engine.progress, color: PresenterView.color(for: phase))
                        .frame(height: max(3, h * 0.04))
                }
            }
        }
    }
}

// MARK: - Message banner

struct MessageBanner: View {
    let text: String
    let flashing: Bool
    let blink: Bool
    let unit: CGFloat
    let atTop: Bool

    var body: some View {
        let flashOff = flashing && !blink
        let yellow = Color(red: 1, green: 0.8, blue: 0.2)
        VStack {
            if !atTop { Spacer() }
            Text(text)
                .font(.system(size: unit * 0.95, weight: .heavy))
                .multilineTextAlignment(.center)
                .foregroundColor(flashOff ? .white : .black)
                .lineLimit(3)
                .minimumScaleFactor(0.3)
                .padding(.vertical, unit * 0.35)
                .padding(.horizontal, unit * 0.6)
                .frame(maxWidth: .infinity)
                .background(flashOff ? Color.black : yellow)
                .overlay(Rectangle().stroke(yellow, lineWidth: max(2, unit * 0.06)))
            if atTop { Spacer() }
        }
        .padding(unit * 0.5)
    }
}

struct ProgressStrip: View {
    var value: Double
    var color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: max(0, g.size.width * CGFloat(value)))
            }
        }
    }
}

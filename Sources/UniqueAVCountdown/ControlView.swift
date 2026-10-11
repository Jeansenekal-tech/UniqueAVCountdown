import SwiftUI

/// The operator window.
struct ControlView: View {
    @EnvironmentObject var engine: TimerEngine
    @State private var selection: Segment.ID?

    var body: some View {
        HSplitView {
            RundownPanel(selection: $selection)
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 560)
            MainPanel()
                .frame(minWidth: 600)
        }
        .frame(minWidth: 960, minHeight: 660)
        .onAppear { selection = engine.currentID }
    }
}

// MARK: - Rundown

struct RundownPanel: View {
    @EnvironmentObject var engine: TimerEngine
    @Binding var selection: Segment.ID?
    @State private var quickMinutes = 5

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Rundown").font(.headline)
                    Spacer()
                    Text("\(engine.segments.count) segments · \(TimeFormat.string(engine.totalRundown))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)

                List(selection: $selection) {
                    ForEach(Array(engine.segments.enumerated()), id: \.element.id) { index, seg in
                        RundownRow(index: index, segment: seg, isCurrent: seg.id == engine.currentID)
                            .tag(seg.id)
                    }
                    .onMove { engine.segments.move(fromOffsets: $0, toOffset: $1) }
                }
                .contextMenu(forSelectionType: Segment.ID.self) { ids in
                    if let id = ids.first {
                        Button("Cue This Segment") { engine.go(to: id) }
                        Button("Cue and Start") { engine.go(to: id, autostart: true) }
                        Divider()
                        Button("Duplicate") { duplicate(id) }
                        Button("Delete") { delete(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { engine.go(to: id) }
                }

                HStack(spacing: 6) {
                    Button { add() } label: { Image(systemName: "plus") }.help("Add segment")
                    Button { if let s = selection { duplicate(s) } } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate").disabled(selection == nil)
                    Button { if let s = selection { delete(s) } } label: { Image(systemName: "minus") }
                        .help("Delete").disabled(selection == nil || engine.segments.count < 2)
                    Spacer()
                    Button("Cue Selected") { if let s = selection { engine.go(to: s) } }
                        .disabled(selection == nil)
                        .help("Load the selected segment (double-click a row does the same)")
                }
                .buttonStyle(.bordered)
                .padding(8)

                HStack(spacing: 6) {
                    Text("Quick timer")
                    TextField("", value: $quickMinutes, format: .number)
                        .frame(width: 46).multilineTextAlignment(.trailing)
                    Stepper("", value: $quickMinutes, in: 1...600).labelsHidden()
                    Text("min").foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Now") { engine.quickTimer(seconds: TimeInterval(quickMinutes * 60)) }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .frame(minHeight: 260)

            Group {
                if let id = selection, engine.segments.contains(where: { $0.id == id }) {
                    SegmentEditor(segment: binding(for: id))
                } else {
                    Text("Select a segment to edit it")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 280)
        }
    }

    private func binding(for id: UUID) -> Binding<Segment> {
        Binding(
            get: { engine.segments.first(where: { $0.id == id }) ?? Segment() },
            set: { new in
                if let i = engine.segments.firstIndex(where: { $0.id == id }) { engine.segments[i] = new }
            }
        )
    }

    private func add() {
        var seg = Segment(title: "Segment \(engine.segments.count + 1)")
        seg.endTime = Date().addingTimeInterval(3600)
        let at = selection.flatMap { id in engine.segments.firstIndex { $0.id == id } }.map { $0 + 1 } ?? engine.segments.count
        engine.segments.insert(seg, at: at)
        selection = seg.id
    }

    private func duplicate(_ id: UUID) {
        guard let i = engine.segments.firstIndex(where: { $0.id == id }) else { return }
        var copy = engine.segments[i]
        copy.id = UUID()
        copy.title += " (copy)"
        engine.segments.insert(copy, at: i + 1)
        selection = copy.id
    }

    private func delete(_ id: UUID) {
        guard engine.segments.count > 1, let i = engine.segments.firstIndex(where: { $0.id == id }) else { return }
        engine.segments.remove(at: i)
        selection = engine.segments[min(i, engine.segments.count - 1)].id
    }
}

struct RundownRow: View {
    let index: Int
    let segment: Segment
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if isCurrent {
                    Image(systemName: "play.fill").foregroundColor(.accentColor)
                } else {
                    Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(segment.title).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                if !segment.speaker.isEmpty {
                    Text(segment.speaker).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if segment.autoAdvance {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).help("Auto-advance")
            }
            Image(systemName: segment.mode.symbol).foregroundStyle(.secondary)
            Text(segment.mode == .endAtTime ? TimerEngine.shortTime(segment.endTime) : TimeFormat.string(segment.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Segment editor

struct SegmentEditor: View {
    @Binding var segment: Segment

    var body: some View {
        Form {
            Section("Segment") {
                TextField("Title", text: $segment.title)
                TextField("Speaker / subtitle", text: $segment.speaker)
                Picker("Timer mode", selection: $segment.mode) {
                    ForEach(TimerMode.allCases) { Text($0.label).tag($0) }
                }
                switch segment.mode {
                case .countdown:
                    DurationField(label: "Duration", seconds: $segment.duration)
                case .countUp:
                    DurationField(label: "Target (0 = none)", seconds: $segment.duration)
                case .endAtTime:
                    DatePicker("Ends at", selection: $segment.endTime, displayedComponents: .hourAndMinute)
                    DurationField(label: "Progress bar window", seconds: $segment.duration)
                }
            }
            Section("Warnings") {
                DurationField(label: "Turn yellow at", seconds: $segment.yellowAt)
                DurationField(label: "Turn red at", seconds: $segment.redAt)
                Toggle("Auto-start next segment at zero", isOn: $segment.autoAdvance)
            }
        }
        .formStyle(.grouped)
    }
}

/// Hours : minutes : seconds entry for a TimeInterval.
struct DurationField: View {
    let label: String
    @Binding var seconds: TimeInterval

    private var total: Int { max(0, Int(seconds)) }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                part(Binding(get: { total / 3600 },
                             set: { seconds = TimeInterval(max(0, $0) * 3600 + total % 3600) }), "h")
                part(Binding(get: { (total % 3600) / 60 },
                             set: { seconds = TimeInterval((total / 3600) * 3600 + max(0, $0) * 60 + total % 60) }), "m")
                part(Binding(get: { total % 60 },
                             set: { seconds = TimeInterval(total - total % 60 + max(0, $0)) }), "s")
            }
        }
    }

    private func part(_ value: Binding<Int>, _ unit: String) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: .number)
                .frame(width: 42)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Main panel

struct MainPanel: View {
    @EnvironmentObject var engine: TimerEngine
    @EnvironmentObject var display: DisplayManager
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            PresenterView(clock: engine.clock)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.35)))
                .overlay(alignment: .topLeading) {
                    Text(display.isShowing ? "● LIVE" : "PREVIEW")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(display.isShowing ? Color.red : Color.gray.opacity(0.6), in: Capsule())
                        .foregroundColor(.white)
                        .padding(8)
                }
                .frame(maxWidth: .infinity)

            TransportBar(clock: engine.clock)

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    MessagePanel()
                    VideoPanel()
                }
                OutputPanel(web: model.web, osc: model.osc, midi: model.midi)
            }
        }
        .padding(14)
    }
}

struct TransportBar: View {
    @EnvironmentObject var engine: TimerEngine
    @ObservedObject var clock: TickClock

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { engine.previous() } label: { Label("Prev", systemImage: "backward.end.fill") }
                Button { engine.toggle() } label: {
                    Label(engine.isRunning ? "Pause" : "Start",
                          systemImage: engine.isRunning ? "pause.fill" : "play.fill")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .orange : .green)
                Button { engine.next() } label: { Label("Next", systemImage: "forward.end.fill") }
                Button { engine.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }

                Divider().frame(height: 24)

                Button("−1:00") { engine.addTime(-60) }
                Button("−0:10") { engine.addTime(-10) }
                Button("+0:10") { engine.addTime(10) }
                Button("+1:00") { engine.addTime(60) }

                Spacer()

                Toggle(isOn: $engine.blackout) { Label("Blackout", systemImage: "moon.fill") }
                    .toggleStyle(.button)
                    .tint(.purple)
            }
            .controlSize(.large)

            HStack(spacing: 18) {
                stat("Elapsed", TimeFormat.string(engine.elapsed))
                stat("Remaining", engine.remaining.map { $0 >= 0 ? TimeFormat.string($0, roundUp: true) : "+" + TimeFormat.string(-$0) } ?? "—")
                stat("Segment", engine.currentIndex.map { "\($0 + 1) of \(engine.segments.count)" } ?? "—")
                stat("Next", engine.nextSegment?.title ?? "—")
                Spacer()
                stat("Time of day", engine.clockText)
            }
            .font(.callout)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).monospacedDigit().lineLimit(1)
        }
    }
}

struct MessagePanel: View {
    @EnvironmentObject var engine: TimerEngine
    @State private var draft = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Message to presenter…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { engine.showMessage(draft) }
                    Button("Show") { engine.showMessage(draft) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                    Button("Flash") { engine.showMessage(draft); engine.flashMessage() }
                    Button("Hide") { engine.hideMessage() }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(engine.settings.cleanPresets, id: \.self) { preset in
                        Button(preset) { draft = preset; engine.showMessage(preset) }
                            .buttonStyle(.bordered)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(engine.messageVisible ? Color.yellow : Color.gray.opacity(0.4)).frame(width: 8, height: 8)
                    Text(engine.messageVisible ? "On screen: \(engine.message)" : "No message on screen")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(4)
        } label: {
            Label("Presenter message", systemImage: "text.bubble")
        }
        .frame(maxWidth: .infinity)
    }
}

struct OutputPanel: View {
    @EnvironmentObject var engine: TimerEngine
    @EnvironmentObject var display: DisplayManager
    @EnvironmentObject var model: AppModel
    @ObservedObject var web: WebRemoteServer
    @ObservedObject var osc: OSCServer
    @ObservedObject var midi: MIDIController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Screen", selection: $display.selectedScreenID) {
                    ForEach(display.screens) { s in
                        Text(s.name).tag(Optional(s.id))
                    }
                }
                Button(display.isShowing ? "Hide Presenter Screen" : "Show Presenter Screen") {
                    display.toggle()
                }
                .buttonStyle(.borderedProminent)
                .tint(display.isShowing ? .red : .accentColor)

                Divider()

                row("iphone", "Phone remote", web.status)
                ForEach(model.remoteURLs, id: \.self) { url in
                    Text(url).font(.callout.monospaced()).textSelection(.enabled).padding(.leading, 22)
                }
                row("dot.radiowaves.left.and.right", "OSC", osc.status)
                row("pianokeys", "MIDI", midi.status)
                row("arrow.down.circle", "Last remote", engine.lastRemoteEvent)
            }
            .padding(4)
        } label: {
            Label("Output & remote", systemImage: "display.2")
        }
        .frame(width: 330)
    }

    private func row(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
            Text(title).fontWeight(.medium)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .font(.callout)
    }
}

// MARK: - Video input / PIP

struct VideoPanel: View {
    @EnvironmentObject var engine: TimerEngine
    @EnvironmentObject var video: VideoInputManager
    @State private var showCrop = false

    private func sources(_ kind: VideoSourceOption.Kind) -> [VideoSourceOption] {
        video.sources.filter { $0.kind == kind }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Picker("Source", selection: Binding(get: { video.selectedID }, set: { video.select($0) })) {
                        Text("None").tag("")
                        if !sources(.device).isEmpty {
                            Section("Capture cards & cameras") {
                                ForEach(sources(.device)) { Text($0.name).tag($0.id) }
                            }
                        }
                        if !sources(.display).isEmpty {
                            Section("Whole display") {
                                ForEach(sources(.display)) { Text($0.name).tag($0.id) }
                            }
                        }
                        if !sources(.window).isEmpty {
                            Section("Window (e.g. PowerPoint Presenter View)") {
                                ForEach(sources(.window)) { Text($0.name).tag($0.id) }
                            }
                        }
                        if video.isActive && !video.sources.contains(where: { $0.id == video.selectedID }) {
                            Text("\(video.selectedName.isEmpty ? "Previous source" : video.selectedName) (not available)")
                                .tag(video.selectedID)
                        }
                    }
                    Button { Task { await video.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh the list of capture devices, displays and windows")
                    Button { video.restart() } label: { Image(systemName: "bolt.horizontal.circle") }
                        .help("Restart the current input")
                        .disabled(!video.isActive)
                }

                if !video.screenAccess {
                    HStack {
                        Text("Displays & windows need Screen Recording permission.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Allow…") { video.requestScreenAccess() }.controlSize(.small)
                    }
                }

                if video.selectedKind == .device && !video.formatLabels.isEmpty {
                    Picker("Format", selection: Binding(get: { video.selectedFormat }, set: { video.selectFormat($0) })) {
                        Text("Auto (device default)").tag("")
                        ForEach(video.formatLabels, id: \.self) { Text($0).tag($0) }
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(video.hasSignal ? Color.green : (video.isActive ? Color.orange : Color.gray.opacity(0.4)))
                        .frame(width: 8, height: 8)
                    Text(video.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if video.videoSize != .zero {
                        Text("\(Int(video.videoSize.width))×\(Int(video.videoSize.height))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Picker("Layout", selection: Binding(get: { engine.settings.videoLayout }, set: { engine.setLayout($0) })) {
                    ForEach(VideoLayout.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }

                HStack(spacing: 10) {
                    let layout = engine.settings.videoLayout
                    if layout == .videoPIP || layout == .timerPIP {
                        Picker("Corner", selection: $engine.settings.pipCorner) {
                            ForEach(PIPCorner.allCases) { Text($0.label).tag($0) }
                        }
                        .frame(width: 170)
                        Text("Size").foregroundStyle(.secondary)
                        Slider(value: $engine.settings.pipSize, in: 0.15...0.6)
                    } else if layout == .split {
                        Text("Video width").foregroundStyle(.secondary)
                        Slider(value: $engine.settings.splitRatio, in: 0.3...0.85)
                    } else {
                        Spacer()
                    }
                    Button("Crop…") { showCrop.toggle() }
                        .popover(isPresented: $showCrop, arrowEdge: .bottom) { CropEditor().environmentObject(engine).padding() }
                }
                .disabled(!video.isActive)

                if !video.isActive && engine.settings.videoLayout != .timerOnly {
                    Text("Choose a source above — until then the presenter screen shows the timer only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("Video input (PIP)", systemImage: "video")
        }
        .frame(maxWidth: .infinity)
    }
}

struct CropEditor: View {
    @EnvironmentObject var engine: TimerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crop the input").font(.headline)
            Text("Use this to show only part of the source, e.g. just the notes area of PowerPoint's Presenter View.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            row("Left", $engine.settings.cropLeft)
            row("Right", $engine.settings.cropRight)
            row("Top", $engine.settings.cropTop)
            row("Bottom", $engine.settings.cropBottom)
            Toggle("Fill the box (crop edges instead of black bars)", isOn: $engine.settings.videoFill)
            HStack {
                Button("Left half") { set(0, 0.5, 0, 0) }
                Button("Right half") { set(0.5, 0, 0, 0) }
                Button("Top half") { set(0, 0, 0, 0.5) }
                Button("Bottom half") { set(0, 0, 0.5, 0) }
                Spacer()
                Button("Reset") { set(0, 0, 0, 0) }
            }
            .controlSize(.small)
        }
        .frame(width: 400)
    }

    private func set(_ l: Double, _ r: Double, _ t: Double, _ b: Double) {
        engine.settings.cropLeft = l
        engine.settings.cropRight = r
        engine.settings.cropTop = t
        engine.settings.cropBottom = b
    }

    private func row(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 56, alignment: .leading)
            Slider(value: value, in: 0...0.5)
            Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}

import SwiftUI
import AppKit
import Combine
import IOKit.pwr_mgt
import UniformTypeIdentifiers

@main
struct UniqueAVCountdownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Unique AV Countdown", id: "control") {
            ControlView()
                .environmentObject(model)
                .environmentObject(model.engine)
                .environmentObject(model.display)
                .environmentObject(model.video)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { TimerCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.engine)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Wires the engine to the presenter display and the remote-control services.
@MainActor
final class AppModel: ObservableObject {
    let engine: TimerEngine
    let video: VideoInputManager
    let display: DisplayManager
    let web: WebRemoteServer
    let osc: OSCServer
    let midi: MIDIController
    let updater: UpdateChecker

    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var sleepAssertion: IOPMAssertionID = 0

    init() {
        let engine = TimerEngine()
        self.engine = engine
        let video = VideoInputManager()
        self.video = video
        display = DisplayManager(engine: engine, video: video)
        web = WebRemoteServer(engine: engine)
        osc = OSCServer(engine: engine)
        midi = MIDIController(engine: engine)
        updater = UpdateChecker()

        applyServices(engine.settings)
        engine.$settings
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.applyServices(s) }
            .store(in: &cancellables)

        installKeyMonitor()
        if engine.settings.checkUpdatesOnLaunch { updater.checkInBackground() }
        // Keep the screens awake for the whole show.
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Unique AV Countdown is running a show" as CFString,
                                    &sleepAssertion)
    }

    private func applyServices(_ s: AppSettings) {
        if s.webEnabled {
            if web.port != s.webPort { web.start(port: s.webPort) }
        } else if web.port != nil { web.stop() }

        if s.oscEnabled {
            if osc.port != s.oscPort { osc.start(port: s.oscPort) }
        } else if osc.port != nil { osc.stop() }

        if s.midiEnabled { midi.start() } else { midi.stop() }
    }

    var remoteURLs: [String] {
        NetworkUtils.localIPv4Addresses().map { "http://\($0):\(engine.settings.webPort)" }
    }

    // MARK: - Keyboard (works whenever you're not typing in a field)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField || responder is NSDatePicker {
                return event
            }
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            let e = self.engine
            switch event.keyCode {
            case 49: e.toggle()                 // space
            case 36, 76: e.toggle()             // return / enter
            case 124: e.next()                  // →
            case 123: e.previous()              // ←
            case 126: e.addTime(60)             // ↑
            case 125: e.addTime(-60)            // ↓
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "r": e.reset()
                case "+", "=": e.addTime(60)
                case "-", "_": e.addTime(-60)
                case "]": e.addTime(10)
                case "[": e.addTime(-10)
                case "f": e.flashMessage()
                case "h": e.hideMessage()
                case "b": e.blackout.toggle()
                case "d": self.display.toggle()
                case "v": e.toggleVideo()
                case "l": e.cycleLayout()
                default: return event
                }
            }
            return nil
        }
    }

    // MARK: - Files

    func newRundown() {
        let alert = NSAlert()
        alert.messageText = "Start a new rundown?"
        alert.informativeText = "The current rundown will be replaced. Save it first if you need it."
        alert.addButton(withTitle: "New Rundown")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { engine.newRundown() }
    }

    func openRundown() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.importRundown(from: url) } catch { showError("Couldn't open rundown", error) }
    }

    func saveRundown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Rundown.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try engine.exportRundown(to: url) } catch { showError("Couldn't save rundown", error) }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

@MainActor
struct TimerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.updater.checkNow() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Rundown") { model.newRundown() }.keyboardShortcut("n")
            Button("Open Rundown…") { model.openRundown() }.keyboardShortcut("o")
            Divider()
            Button("Save Rundown As…") { model.saveRundown() }.keyboardShortcut("s")
        }
        CommandMenu("Timer") {
            Button("Start / Pause") { model.engine.toggle() }.keyboardShortcut(.return, modifiers: .command)
            Button("Reset Segment") { model.engine.reset() }.keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Next Segment") { model.engine.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Segment") { model.engine.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Add 1 Minute") { model.engine.addTime(60) }.keyboardShortcut("=", modifiers: .command)
            Button("Remove 1 Minute") { model.engine.addTime(-60) }.keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("Flash Message") { model.engine.flashMessage() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Hide Message") { model.engine.hideMessage() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Toggle Blackout") { model.engine.blackout.toggle() }.keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Video PIP On / Off") { model.engine.toggleVideo() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Next Video Layout") { model.engine.cycleLayout() }.keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Show / Hide Presenter Screen") { model.display.toggle() }.keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}

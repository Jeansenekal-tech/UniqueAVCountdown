import AppKit
import SwiftUI

struct ScreenInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isMain: Bool
}

/// Owns the presenter window and puts it full-screen on the chosen display.
@MainActor
final class DisplayManager: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var screens: [ScreenInfo] = []
    @Published private(set) var isShowing = false
    @Published var selectedScreenID: CGDirectDisplayID? {
        didSet {
            if let id = selectedScreenID { UserDefaults.standard.set(Int(id), forKey: "presenterScreen") }
            if isShowing { show() }
        }
    }

    private let engine: TimerEngine
    private let video: VideoInputManager
    private var window: NSWindow?

    init(engine: TimerEngine, video: VideoInputManager) {
        self.engine = engine
        self.video = video
        super.init()
        let saved = UserDefaults.standard.integer(forKey: "presenterScreen")
        if saved != 0 { selectedScreenID = CGDirectDisplayID(saved) }
        refreshScreens()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
    }

    private static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func refreshScreens() {
        let all = NSScreen.screens
        screens = all.enumerated().map { i, s in
            let f = s.frame
            return ScreenInfo(id: Self.displayID(s),
                              name: "\(s.localizedName) — \(Int(f.width))×\(Int(f.height))\(i == 0 ? " (main)" : "")",
                              isMain: i == 0)
        }
        if selectedScreenID == nil || !screens.contains(where: { $0.id == selectedScreenID }) {
            // Prefer an external display for the presenter.
            let pick = screens.first(where: { !$0.isMain }) ?? screens.first
            if pick?.id != selectedScreenID { selectedScreenID = pick?.id }
        }
    }

    private func screensChanged() {
        refreshScreens()
        if isShowing { show() }
    }

    func toggle() { isShowing ? hide() : show() }

    func show() {
        let target = NSScreen.screens.first(where: { Self.displayID($0) == selectedScreenID })
            ?? NSScreen.screens.last ?? NSScreen.main
        guard let screen = target else { return }
        let onlyOneScreen = NSScreen.screens.count < 2
        let isMainScreen = screen == NSScreen.screens.first

        window?.delegate = nil
        window?.orderOut(nil)

        let root = PresenterView(clock: engine.clock)
            .environmentObject(engine)
            .environmentObject(video)
        let w: NSWindow
        if onlyOneScreen || isMainScreen {
            // Windowed when there's no external display, so you can test and still use the controls.
            let size = NSSize(width: 960, height: 540)
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                 y: screen.visibleFrame.midY - size.height / 2)
            w = NSWindow(contentRect: NSRect(origin: origin, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
            w.title = "Presenter Display"
            w.contentAspectRatio = NSSize(width: 16, height: 9)
            w.level = .floating
            w.collectionBehavior = [.fullScreenPrimary]
        } else {
            w = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                         backing: .buffered, defer: false, screen: screen)
            w.setFrame(screen.frame, display: true)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.hidesOnDeactivate = false
        }
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: root)
        w.delegate = self
        w.orderFrontRegardless()
        window = w
        isShowing = true
    }

    func hide() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        isShowing = false
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            self.isShowing = false
        }
    }
}

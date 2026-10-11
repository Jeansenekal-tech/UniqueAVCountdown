import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// A selectable video source: a capture device (USB capture card, webcam, Continuity Camera,
/// NDI Virtual Input…), a whole display, or a single window (e.g. PowerPoint Presenter View).
struct VideoSourceOption: Identifiable, Hashable {
    enum Kind: String { case device, display, window }
    let id: String          // "device:<uniqueID>", "display:<CGDirectDisplayID>", "window:<CGWindowID>"
    let name: String
    let kind: Kind
}

// MARK: - Frame fan-out

/// Receives frames from whichever capture is running and pushes them to every visible
/// video layer (operator preview + presenter screen). Thread-safe.
final class FrameBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private let layers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    private var generation = 0
    private var lastFrame: CFAbsoluteTime = 0
    private var size: CGSize = .zero
    private var latest: CMSampleBuffer?   // so a newly opened screen shows a picture straight away

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        layers.add(layer)
        let frame = latest
        lock.unlock()
        if let frame { layer.enqueue(frame) }
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); layers.remove(layer); lock.unlock()
    }

    /// Starts a new capture "generation"; frames from older captures are ignored.
    func begin() -> Int {
        lock.lock(); generation += 1; let g = generation; lock.unlock()
        clearLayers()
        return g
    }

    func end() {
        lock.lock(); generation += 1; lock.unlock()
        clearLayers()
    }

    func isCurrent(_ g: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return g == generation
    }

    func push(_ sb: CMSampleBuffer, generation g: Int) {
        guard CMSampleBufferIsValid(sb), let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        Self.markDisplayImmediately(sb)

        lock.lock()
        guard g == generation else { lock.unlock(); return }
        lastFrame = CFAbsoluteTimeGetCurrent()
        size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        latest = sb
        let targets = layers.allObjects
        lock.unlock()

        for layer in targets {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sb)
        }
    }

    /// Screen capture only sends frames when the picture changes; idle ticks keep the source "alive".
    func heartbeat(generation g: Int) {
        lock.lock()
        if g == generation, size != .zero { lastFrame = CFAbsoluteTimeGetCurrent() }
        lock.unlock()
    }

    /// Seconds since the last frame, and the current frame size.
    var signal: (age: Double, size: CGSize) {
        lock.lock(); defer { lock.unlock() }
        return (lastFrame == 0 ? .infinity : CFAbsoluteTimeGetCurrent() - lastFrame, size)
    }

    private func clearLayers() {
        lock.lock()
        lastFrame = 0
        size = .zero
        latest = nil
        let targets = layers.allObjects
        lock.unlock()
        DispatchQueue.main.async { targets.forEach { $0.flushAndRemoveImage() } }
    }

    /// Live video: show each frame as soon as it arrives instead of waiting on timestamps.
    private static func markDisplayImmediately(_ sb: CMSampleBuffer) {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(array) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

enum VideoInputError: LocalizedError {
    case cannotUse(String)
    var errorDescription: String? {
        switch self {
        case .cannotUse(let name): return "\(name) can't be opened (is another app using it?)"
        }
    }
}

// MARK: - Capture devices (AVFoundation)

struct CaptureFormatOption {
    let label: String
    let width: Int32
    let height: Int32
    let fps: Int
    let format: AVCaptureDevice.Format
}

final class DeviceCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "za.uniqueav.countdown.device-capture")
    private let sink: FrameBroadcaster
    private let generation: Int

    init(device: AVCaptureDevice, formatLabel: String, sink: FrameBroadcaster, generation: Int) throws {
        self.sink = sink
        self.generation = generation
        super.init()

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw VideoInputError.cannotUse(device.localizedName) }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        let preferred = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if output.availableVideoPixelFormatTypes.contains(preferred) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: preferred]
        }
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw VideoInputError.cannotUse(device.localizedName) }
        session.addOutput(output)

        if !formatLabel.isEmpty,
           let option = DeviceCapture.formats(for: device).first(where: { $0.label == formatLabel }) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = option.format
                device.unlockForConfiguration()
            } catch {
                // Keep the device's default format.
            }
        }
    }

    func start() { queue.async { self.session.startRunning() } }
    func stop() { queue.async { self.session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sink.push(sampleBuffer, generation: generation)
    }

    /// The device's resolutions / frame rates, largest first.
    static func formats(for device: AVCaptureDevice) -> [CaptureFormatOption] {
        var seen = Set<String>()
        var out: [CaptureFormatOption] = []
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = Int((f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0).rounded())
            let label = "\(d.width)×\(d.height) @ \(fps) fps"
            if seen.insert(label).inserted {
                out.append(CaptureFormatOption(label: label, width: d.width, height: d.height, fps: fps, format: f))
            }
        }
        return out.sorted {
            let a = Int($0.width) * Int($0.height), b = Int($1.width) * Int($1.height)
            return a != b ? a > b : $0.fps > $1.fps
        }
    }

    static func devices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .deskViewCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
            .devices
            .filter { $0.isConnected }
    }
}

// MARK: - Screen / window capture (ScreenCaptureKit)

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var activeStream: SCStream?
    private let queue = DispatchQueue(label: "za.uniqueav.countdown.screen-capture")
    private let sink: FrameBroadcaster
    private let generation: Int
    var onStop: (@MainActor (Error) -> Void)?

    init(sink: FrameBroadcaster, generation: Int) {
        self.sink = sink
        self.generation = generation
    }

    func start(filter: SCContentFilter, pixelSize: CGSize) async throws {
        let cfg = SCStreamConfiguration()
        cfg.width = max(16, Int(pixelSize.width))
        cfg.height = max(16, Int(pixelSize.height))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.queueDepth = 5
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        activeStream = s
        try await s.startCapture()
    }

    func stop() {
        guard let s = activeStream else { return }
        activeStream = nil
        Task { try? await s.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                          as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete: sink.push(sampleBuffer, generation: generation)
        case .idle: sink.heartbeat(generation: generation)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = onStop
        Task { @MainActor in handler?(error) }
    }
}

// MARK: - Manager

@MainActor
final class VideoInputManager: ObservableObject {
    @Published private(set) var sources: [VideoSourceOption] = []
    @Published private(set) var selectedID = ""          // "" = no video input
    @Published private(set) var selectedName = ""
    @Published private(set) var formatLabels: [String] = []
    @Published private(set) var selectedFormat = ""      // "" = device default
    @Published private(set) var status = "No video input"
    @Published private(set) var hasSignal = false
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var screenAccess = CGPreflightScreenCaptureAccess()

    let broadcaster = FrameBroadcaster()

    private var deviceCapture: DeviceCapture?
    private var screenCapture: ScreenCapture?
    private var scDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    private var scWindows: [CGWindowID: SCWindow] = [:]
    private var ownApp: SCRunningApplication?
    private var monitor: Timer?
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { !selectedID.isEmpty }

    var selectedKind: VideoSourceOption.Kind? {
        guard let prefix = selectedID.split(separator: ":").first else { return nil }
        return VideoSourceOption.Kind(rawValue: String(prefix))
    }

    init() {
        let d = UserDefaults.standard
        let savedID = d.string(forKey: "videoSource") ?? ""
        let savedName = d.string(forKey: "videoSourceName") ?? ""
        selectedFormat = d.string(forKey: "videoFormat") ?? ""

        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.devicesChanged() }
            })
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSignal() }
        }
        RunLoop.main.add(t, forMode: .common)
        monitor = t

        Task {
            await refresh()
            if !savedID.isEmpty { restore(id: savedID, name: savedName) }
        }
    }

    // MARK: Source list

    func refresh() async {
        var list = DeviceCapture.devices().map {
            VideoSourceOption(id: "device:\($0.uniqueID)", name: $0.localizedName, kind: .device)
        }
        screenAccess = CGPreflightScreenCaptureAccess()
        if screenAccess {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let pid = ProcessInfo.processInfo.processIdentifier
                ownApp = content.applications.first { $0.processID == pid }

                scDisplays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
                for (i, display) in content.displays.enumerated() {
                    let screenName = NSScreen.screens.first { Self.displayID($0) == display.displayID }?.localizedName
                        ?? "Display \(i + 1)"
                    list.append(VideoSourceOption(id: "display:\(display.displayID)",
                                                  name: "\(screenName) (\(display.width)×\(display.height))",
                                                  kind: .display))
                }

                let windows = content.windows.filter {
                    $0.windowLayer == 0 && $0.frame.width >= 160 && $0.frame.height >= 120
                        && $0.owningApplication?.processID != pid
                        && !($0.owningApplication?.applicationName ?? "").isEmpty
                }
                scWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
                list += windows.map { w in
                    let app = w.owningApplication?.applicationName ?? "Window"
                    let title = w.title ?? ""
                    return VideoSourceOption(id: "window:\(w.windowID)",
                                             name: title.isEmpty ? app : "\(app) — \(title)",
                                             kind: .window)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                screenAccess = false
            }
        }
        sources = list
        updateFormats()
    }

    /// Opens the macOS Screen Recording permission prompt.
    func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess() {
            status = "Allow Unique AV Countdown in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen the app."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        Task { await refresh() }
    }

    // MARK: Selection

    func select(_ id: String) {
        stopCapture()
        selectedID = id
        selectedName = sources.first { $0.id == id }?.name ?? ""
        let d = UserDefaults.standard
        d.set(id, forKey: "videoSource")
        d.set(selectedName, forKey: "videoSourceName")
        updateFormats()
        startSelected()
    }

    func selectFormat(_ label: String) {
        selectedFormat = label
        UserDefaults.standard.set(label, forKey: "videoFormat")
        if selectedKind == .device {
            stopCapture()
            startSelected()
        }
    }

    func restart() {
        stopCapture()
        startSelected()
    }

    private func restore(id: String, name: String) {
        if sources.contains(where: { $0.id == id }) {
            select(id)
            return
        }
        // Window/display IDs change between launches; match by name instead.
        let kind = id.split(separator: ":").first.map(String.init)
        if !name.isEmpty, let match = sources.first(where: { $0.name == name && $0.kind.rawValue == kind }) {
            select(match.id)
            return
        }
        selectedID = id
        selectedName = name
        if kind == "device" {
            status = "Waiting for \(name.isEmpty ? "capture device" : name) to connect…"
        } else {
            status = screenAccess ? "\(name) isn't open — choose another source or click Refresh"
                                  : "Allow screen capture to use \(name)"
        }
    }

    private func updateFormats() {
        if selectedKind == .device, let dev = AVCaptureDevice(uniqueID: String(selectedID.dropFirst(7))) {
            formatLabels = DeviceCapture.formats(for: dev).map(\.label)
        } else {
            formatLabels = []
        }
    }

    private func startSelected() {
        guard let kind = selectedKind else {
            status = "No video input"
            return
        }
        let value = String(selectedID.split(separator: ":", maxSplits: 1).last ?? "")
        let gen = broadcaster.begin()
        switch kind {
        case .device: startDevice(uniqueID: value, generation: gen)
        case .display: startDisplay(CGDirectDisplayID(value) ?? 0, generation: gen)
        case .window: startWindow(CGWindowID(value) ?? 0, generation: gen)
        }
    }

    private func startDevice(uniqueID: String, generation gen: Int) {
        guard let dev = AVCaptureDevice(uniqueID: uniqueID), dev.isConnected else {
            status = "\(selectedName.isEmpty ? "Device" : selectedName) not connected — waiting…"
            return
        }
        status = "Opening \(dev.localizedName)…"
        Task {
            let allowed = await Self.cameraAccess()
            guard broadcaster.isCurrent(gen) else { return }
            guard allowed else {
                status = "Camera access is off — allow it in System Settings › Privacy & Security › Camera"
                return
            }
            do {
                let cap = try DeviceCapture(device: dev, formatLabel: selectedFormat, sink: broadcaster, generation: gen)
                deviceCapture = cap
                cap.start()
                status = "Capturing \(dev.localizedName)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func startDisplay(_ id: CGDirectDisplayID, generation gen: Int) {
        guard let display = scDisplays[id] else {
            status = screenAccess ? "That display isn't available — click Refresh" : "Allow screen capture first"
            return
        }
        let scale = NSScreen.screens.first { Self.displayID($0) == id }?.backingScaleFactor ?? 2
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ownApp.map { [$0] } ?? [],
                                     exceptingWindows: [])
        startScreen(filter: filter,
                    size: Self.capped(CGSize(width: CGFloat(display.width) * scale,
                                             height: CGFloat(display.height) * scale)),
                    generation: gen)
    }

    private func startWindow(_ id: CGWindowID, generation gen: Int) {
        guard let window = scWindows[id] else {
            status = "That window isn't open any more — click Refresh"
            return
        }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        startScreen(filter: SCContentFilter(desktopIndependentWindow: window),
                    size: Self.capped(CGSize(width: window.frame.width * scale, height: window.frame.height * scale)),
                    generation: gen)
    }

    private func startScreen(filter: SCContentFilter, size: CGSize, generation gen: Int) {
        let cap = ScreenCapture(sink: broadcaster, generation: gen)
        let name = selectedName
        cap.onStop = { [weak self, weak cap] error in
            guard let self, let cap, self.screenCapture === cap else { return }
            self.screenCapture = nil
            self.status = "Capture stopped (\(error.localizedDescription)) — reselect the source"
        }
        screenCapture = cap
        status = "Starting capture…"
        Task {
            do {
                try await cap.start(filter: filter, pixelSize: size)
                if screenCapture === cap { status = "Capturing \(name)" }
            } catch {
                if screenCapture === cap {
                    screenCapture = nil
                    status = "Couldn't capture: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopCapture() {
        deviceCapture?.stop()
        deviceCapture = nil
        screenCapture?.stop()
        screenCapture = nil
        broadcaster.end()
        hasSignal = false
        videoSize = .zero
    }

    // MARK: Monitoring

    private func devicesChanged() {
        Task {
            await refresh()
            guard selectedKind == .device else { return }
            let uid = String(selectedID.dropFirst(7))
            if AVCaptureDevice(uniqueID: uid)?.isConnected == true {
                if deviceCapture == nil { startSelected() }
            } else if deviceCapture != nil {
                stopCapture()
                status = "\(selectedName) disconnected — waiting for it to come back…"
            }
        }
    }

    private func checkSignal() {
        let s = broadcaster.signal
        // A captured window/display that isn't changing still counts as live.
        let staticScreen = screenCapture != nil && s.size != .zero
        let live = isActive && (s.age < 1.5 || staticScreen)
        if live != hasSignal { hasSignal = live }
        if live, s.size != videoSize { videoSize = s.size }
    }

    // MARK: Helpers

    static func cameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Keeps capture size at or below 4K on the long side.
    static func capped(_ size: CGSize) -> CGSize {
        let longSide = max(size.width, size.height)
        guard longSide > 3840 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        let k = 3840 / longSide
        return CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
    }
}

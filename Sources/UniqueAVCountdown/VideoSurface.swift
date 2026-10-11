import SwiftUI
import AppKit
import AVFoundation

struct VideoCrop: Equatable {
    var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0
}

/// AppKit view hosting a sample-buffer layer fed by the FrameBroadcaster.
/// Handles cropping and fit/fill by sizing the video layer inside a clipping layer.
final class VideoSurfaceNSView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    private weak var broadcaster: FrameBroadcaster?

    var crop = VideoCrop() { didSet { if crop != oldValue { updateVideoFrame() } } }
    var fill = false { didSet { if fill != oldValue { updateVideoFrame() } } }
    var videoSize = CGSize.zero { didSet { if videoSize != oldValue { updateVideoFrame() } } }

    init(broadcaster: FrameBroadcaster) {
        self.broadcaster = broadcaster
        super.init(frame: .zero)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { broadcaster?.attach(videoLayer) } else { broadcaster?.detach(videoLayer) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVideoFrame()
    }

    func detach() { broadcaster?.detach(videoLayer) }

    private func updateVideoFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = computeFrame()
        CATransaction.commit()
    }

    private func computeFrame() -> CGRect {
        let b = bounds
        guard videoSize.width > 0, videoSize.height > 0, b.width > 0, b.height > 0 else {
            videoLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            return b
        }
        videoLayer.videoGravity = .resize

        func clamp(_ v: Double) -> CGFloat { CGFloat(min(0.5, max(0, v))) }
        var l = clamp(crop.left), r = clamp(crop.right), t = clamp(crop.top), bt = clamp(crop.bottom)
        // Always leave at least 10% of the picture visible in each direction.
        if l + r > 0.9 { let k = 0.9 / (l + r); l *= k; r *= k }
        if t + bt > 0.9 { let k = 0.9 / (t + bt); t *= k; bt *= k }
        let w = videoSize.width, h = videoSize.height
        let visibleW = w * (1 - l - r), visibleH = h * (1 - t - bt)
        let s = fill ? max(b.width / visibleW, b.height / visibleH)
                     : min(b.width / visibleW, b.height / visibleH)
        // Layer coordinates start bottom-left, so the bottom crop moves the picture down.
        let x = (b.width - visibleW * s) / 2 - l * w * s
        let y = (b.height - visibleH * s) / 2 - bt * h * s
        return CGRect(x: x, y: y, width: w * s, height: h * s)
    }
}

struct VideoSurface: NSViewRepresentable {
    let broadcaster: FrameBroadcaster
    var videoSize: CGSize
    var crop: VideoCrop
    var fill: Bool

    func makeNSView(context: Context) -> VideoSurfaceNSView {
        VideoSurfaceNSView(broadcaster: broadcaster)
    }

    func updateNSView(_ view: VideoSurfaceNSView, context: Context) {
        view.videoSize = videoSize
        view.crop = crop
        view.fill = fill
    }

    static func dismantleNSView(_ view: VideoSurfaceNSView, coordinator: ()) {
        view.detach()
    }
}

/// The live input, with a "no signal" card when nothing is coming in.
struct VideoBox: View {
    @EnvironmentObject var engine: TimerEngine
    @EnvironmentObject var video: VideoInputManager

    var body: some View {
        let s = engine.settings
        GeometryReader { geo in
            let u = max(8, min(geo.size.width / 16, geo.size.height / 9))
            ZStack {
                Color.black
                VideoSurface(broadcaster: video.broadcaster,
                             videoSize: video.videoSize,
                             crop: VideoCrop(left: s.cropLeft, right: s.cropRight, top: s.cropTop, bottom: s.cropBottom),
                             fill: s.videoFill)
                if !video.hasSignal {
                    VStack(spacing: u * 0.2) {
                        Image(systemName: "video.slash")
                            .font(.system(size: u * 0.9))
                        Text(video.isActive ? "No signal" : "No video input")
                            .font(.system(size: u * 0.45, weight: .semibold))
                        if !video.selectedName.isEmpty {
                            Text(video.selectedName)
                                .font(.system(size: u * 0.3))
                                .lineLimit(1)
                        }
                    }
                    .foregroundColor(.white.opacity(0.45))
                    .padding(u * 0.3)
                }
            }
        }
        .clipped()
    }
}

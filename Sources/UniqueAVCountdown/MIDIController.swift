import Foundation
import CoreMIDI

/// Listens to every MIDI input. Notes from the base note upward trigger commands
/// (see MIDIMap.commands); Program Change N cues segment N+1. CC numbers use the
/// same map as notes (value ≥ 64 triggers).
final class MIDIController: ObservableObject {
    @Published private(set) var status = "Off"
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected = Set<MIDIEndpointRef>()
    private(set) var isRunning = false
    private weak var engine: TimerEngine?

    init(engine: TimerEngine) { self.engine = engine }

    func start() {
        guard !isRunning else { return }
        var st = MIDIClientCreateWithBlock("Unique AV Countdown" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectSources() }
            }
        }
        guard st == noErr else { status = "MIDI unavailable (\(st))"; return }

        st = MIDIInputPortCreateWithProtocol(client, "Countdown Input" as CFString, ._1_0, &port) { [weak self] list, _ in
            var events: [(UInt8, UInt8, UInt8)] = []
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafeBytes(of: packet.pointee.words) { raw in
                    let words = raw.bindMemory(to: UInt32.self)
                    for i in 0..<min(count, words.count) {
                        let w = words[i]
                        // UMP type 2 = MIDI 1.0 channel voice message
                        if w >> 28 == 0x2 {
                            events.append((UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F)))
                        }
                    }
                }
            }
            guard !events.isEmpty else { return }
            let received = events
            DispatchQueue.main.async {
                for e in received { self?.handle(status: e.0, data1: e.1, data2: e.2) }
            }
        }
        guard st == noErr else { status = "MIDI port error (\(st))"; return }
        isRunning = true
        connectSources()
    }

    func stop() {
        guard isRunning else { return }
        MIDIPortDispose(port)
        MIDIClientDispose(client)
        connected.removeAll()
        isRunning = false
        status = "Off"
    }

    private func connectSources() {
        guard isRunning else { return }
        var live = Set<MIDIEndpointRef>()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            live.insert(src)
            if !connected.contains(src) {
                MIDIPortConnectSource(port, src, nil)
                connected.insert(src)
            }
        }
        connected.formIntersection(live)
        status = live.isEmpty ? "Listening — no MIDI devices found" : "Listening to \(live.count) MIDI source\(live.count == 1 ? "" : "s")"
    }

    private func handle(status: UInt8, data1: UInt8, data2: UInt8) {
        guard let engine else { return }
        let type = status & 0xF0
        let channel = Int(status & 0x0F) + 1
        let wanted = engine.settings.midiChannel
        if wanted != 0 && wanted != channel { return }

        switch type {
        case 0x90 where data2 > 0, 0xB0 where data2 >= 64:
            let offset = Int(data1) - engine.settings.midiBaseNote
            guard MIDIMap.commands.indices.contains(offset) else {
                engine.lastRemoteEvent = "MIDI: \(type == 0x90 ? "note" : "CC") \(data1) ch\(channel) (unmapped)"
                return
            }
            engine.perform(command: MIDIMap.commands[offset].command, source: "MIDI \(type == 0x90 ? "note" : "CC") \(data1)")
        case 0xC0:
            engine.perform(command: "goto", argument: String(Int(data1) + 1), source: "MIDI PC \(data1)")
        default:
            break
        }
    }
}

import Foundation
import Network

/// Receives OSC over UDP. Addresses: /timer/<command> [argument]
/// e.g. /timer/start, /timer/next, /timer/add 30, /timer/goto 3, /timer/message "Wrap up"
final class OSCServer: ObservableObject {
    @Published private(set) var status = "Off"
    private(set) var port: Int?
    private var listener: NWListener?
    private weak var engine: TimerEngine?

    /// Commands that use their argument; for everything else a numeric 0 is treated as a
    /// button release (Companion / TouchOSC send 1 on press, 0 on release).
    private static let argCommands: Set<String> = ["add", "sub", "goto", "cue", "segment",
                                                   "message", "message-show", "message-flash",
                                                   "flash", "blackout", "quick", "layout"]

    init(engine: TimerEngine) { self.engine = engine }

    func start(port: Int) {
        stop()
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: p)
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.status = "Listening on UDP \(port)"
                    case .failed(let e): self?.status = "Error: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in
                c.start(queue: .main)
                self?.receive(c)
            }
            l.start(queue: .main)
            listener = l
            self.port = port
            status = "Starting…"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        status = "Off"
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let data { self?.handle(packet: [UInt8](data)) }
            if error == nil { self?.receive(c) } else { c.cancel() }
        }
    }

    // MARK: - Parsing

    private func handle(packet b: [UInt8]) {
        if b.starts(with: Array("#bundle".utf8)) {
            var i = 16   // "#bundle\0" + 8-byte timetag
            while i + 4 <= b.count {
                let size = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                i += 4
                guard size > 0, i + size <= b.count else { break }
                handle(packet: Array(b[i..<(i + size)]))
                i += size
            }
            return
        }
        guard let (address, args) = Self.parseMessage(b) else { return }
        route(address: address, args: args)
    }

    private func route(address: String, args: [String]) {
        var path = address.lowercased()
        for prefix in ["/timer/", "/countdown/", "/uniqueav/", "/"] where path.hasPrefix(prefix) {
            path.removeFirst(prefix.count)
            break
        }
        let command = path.replacingOccurrences(of: "/", with: "-")
        let arg = args.first
        if !Self.argCommands.contains(command), let a = arg, let n = Double(a), n == 0 {
            return // button release
        }
        engine?.perform(command: command,
                        argument: Self.argCommands.contains(command) ? arg : nil,
                        source: "OSC")
    }

    /// Returns the address and arguments (as strings) of an OSC message.
    static func parseMessage(_ b: [UInt8]) -> (String, [String])? {
        var i = 0
        guard let address = readString(b, &i), address.hasPrefix("/") else { return nil }
        guard i < b.count, let tags = readString(b, &i), tags.hasPrefix(",") else { return (address, []) }
        var args: [String] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard i + 4 <= b.count else { return (address, args) }
                let v = Int32(bitPattern: UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
                args.append(String(v)); i += 4
            case "f":
                guard i + 4 <= b.count else { return (address, args) }
                let bits = UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
                let f = Float(bitPattern: bits)
                args.append(f == f.rounded() && abs(f) < 1e9 ? String(Int(f)) : String(f)); i += 4
            case "d":
                guard i + 8 <= b.count else { return (address, args) }
                var bits: UInt64 = 0
                for k in 0..<8 { bits = bits << 8 | UInt64(b[i + k]) }
                args.append(String(Double(bitPattern: bits))); i += 8
            case "s", "S":
                guard let s = readString(b, &i) else { return (address, args) }
                args.append(s)
            case "T": args.append("1")
            case "F": args.append("0")
            case "N", "I": continue
            default:
                return (address, args)
            }
        }
        return (address, args)
    }

    private static func readString(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i < b.count, let end = b[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: b[i..<end], as: UTF8.self)
        i = (end + 4) & ~3   // skip null + padding to 4-byte boundary
        return s
    }
}

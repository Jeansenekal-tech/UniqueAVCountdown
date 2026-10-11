import Foundation
import Network

/// Tiny HTTP server: serves the phone remote page and a JSON API.
///   GET /                 → remote page
///   GET /api/state        → current state (JSON)
///   GET /api/cmd?c=next   → run a command (optional &v=value)
final class WebRemoteServer: ObservableObject {
    @Published private(set) var status = "Off"
    private(set) var port: Int?
    private var listener: NWListener?
    private weak var engine: TimerEngine?

    init(engine: TimerEngine) { self.engine = engine }

    func start(port: Int) {
        stop()
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: p)
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.status = "Running on port \(port)"
                    case .failed(let e): self?.status = "Error: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
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

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(c, head: head)
            } else if done || error != nil || buf.count > 65536 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let comps = URLComponents(string: "http://remote" + target)
        let path = comps?.path ?? "/"
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }

        var code = "200 OK"
        var type = "text/html; charset=utf-8"
        var body = Data()

        switch path {
        case "/", "/index.html", "/remote":
            body = Data(RemotePage.html.utf8)
        case "/api/state":
            type = "application/json"
            body = engine?.stateJSON() ?? Data("{}".utf8)
        case "/api/cmd":
            let ok = engine?.perform(command: query["c"] ?? "", argument: query["v"], source: "Web") ?? false
            type = "application/json"
            body = Data("{\"ok\":\(ok)}".utf8)
        default:
            code = "404 Not Found"
            type = "text/plain"
            body = Data("Not found".utf8)
        }

        let header = "HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

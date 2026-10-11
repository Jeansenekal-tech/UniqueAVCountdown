// Small HTTP server: the phone remote page plus a JSON API.
//   GET /                 → remote page
//   GET /api/state        → current state (JSON)
//   GET /api/cmd?c=next   → run a command (optional &v=value)
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PAGE = fs.readFileSync(path.join(__dirname, '..', 'remote', 'remote.html'));

class WebRemoteServer {
  /** @param {{state: () => object, command: (c: string, v: string|null) => boolean}} handlers */
  constructor(handlers) {
    this.handlers = handlers;
    this.server = null;
    this.port = null;
    this.status = 'Off';
  }

  start(port) {
    this.stop();
    const server = http.createServer((req, res) => this.handle(req, res));
    server.on('error', (e) => {
      this.status = `Error: ${e.code === 'EADDRINUSE' ? `port ${port} is in use by another app` : e.message}`;
    });
    server.listen(port, '0.0.0.0', () => { this.status = `Running on port ${port}`; });
    this.server = server;
    this.port = port;
    this.status = 'Starting…';
  }

  stop() {
    if (this.server) { try { this.server.close(); } catch { /* not running */ } }
    this.server = null;
    this.port = null;
    this.status = 'Off';
  }

  handle(req, res) {
    const url = new URL(req.url, 'http://remote');
    const send = (code, type, body) => {
      res.writeHead(code, {
        'Content-Type': type,
        'Cache-Control': 'no-store',
        'Access-Control-Allow-Origin': '*',
      });
      res.end(body);
    };
    switch (url.pathname) {
      case '/': case '/index.html': case '/remote':
        return send(200, 'text/html; charset=utf-8', PAGE);
      case '/api/state':
        return send(200, 'application/json', JSON.stringify(this.handlers.state()));
      case '/api/cmd': {
        const ok = this.handlers.command(url.searchParams.get('c') || '', url.searchParams.get('v'));
        return send(200, 'application/json', JSON.stringify({ ok }));
      }
      default:
        return send(404, 'text/plain', 'Not found');
    }
  }
}

/** IPv4 addresses of this computer's network adapters (Wi-Fi, Ethernet…). */
function localIPv4() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    if (/^(utun|awdl|llw|lo|vEthernet|VirtualBox|VMware|docker|br-)/i.test(name)) continue;
    for (const a of list || []) {
      if ((a.family === 'IPv4' || a.family === 4) && !a.internal && !out.includes(a.address)) out.push(a.address);
    }
  }
  return out;
}

module.exports = { WebRemoteServer, localIPv4 };

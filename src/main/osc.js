// OSC over UDP. Addresses: /timer/<command> [argument]
// e.g. /timer/start, /timer/next, /timer/add 30, /timer/goto 3, /timer/message "Wrap up"
const dgram = require('dgram');

// Commands that use their argument. For everything else a numeric 0 is a button
// release (Companion / TouchOSC send 1 on press, 0 on release) and is ignored.
const ARG_COMMANDS = new Set(['add', 'sub', 'goto', 'cue', 'segment', 'message', 'message-show',
  'message-flash', 'flash', 'blackout', 'quick', 'layout']);

function readString(buf, i) {
  const end = buf.indexOf(0, i);
  if (end < 0) return null;
  const s = buf.toString('utf8', i, end);
  return { value: s, next: (end + 4) & ~3 };
}

/** Parses one OSC message → { address, args } (args as strings), or null. */
function parseMessage(buf) {
  const a = readString(buf, 0);
  if (!a || !a.value.startsWith('/')) return null;
  const address = a.value;
  let i = a.next;
  const args = [];
  if (i >= buf.length) return { address, args };
  const t = readString(buf, i);
  if (!t || !t.value.startsWith(',')) return { address, args };
  i = t.next;
  for (const tag of t.value.slice(1)) {
    switch (tag) {
      case 'i':
        if (i + 4 > buf.length) return { address, args };
        args.push(String(buf.readInt32BE(i))); i += 4; break;
      case 'f': {
        if (i + 4 > buf.length) return { address, args };
        const f = buf.readFloatBE(i); i += 4;
        args.push(Number.isInteger(f) ? String(f) : String(Math.round(f * 1e6) / 1e6));
        break;
      }
      case 'd':
        if (i + 8 > buf.length) return { address, args };
        args.push(String(buf.readDoubleBE(i))); i += 8; break;
      case 'h':
        if (i + 8 > buf.length) return { address, args };
        args.push(String(buf.readBigInt64BE(i))); i += 8; break;
      case 's': case 'S': {
        const s = readString(buf, i);
        if (!s) return { address, args };
        args.push(s.value); i = s.next; break;
      }
      case 'T': args.push('1'); break;
      case 'F': args.push('0'); break;
      case 'N': case 'I': break;
      default: return { address, args };
    }
  }
  return { address, args };
}

/** Expands bundles into messages. */
function parsePacket(buf, out = []) {
  if (buf.length >= 16 && buf.toString('utf8', 0, 7) === '#bundle') {
    let i = 16;
    while (i + 4 <= buf.length) {
      const size = buf.readInt32BE(i); i += 4;
      if (size <= 0 || i + size > buf.length) break;
      parsePacket(buf.subarray(i, i + size), out);
      i += size;
    }
  } else {
    const m = parseMessage(buf);
    if (m) out.push(m);
  }
  return out;
}

/** Turns an OSC address + args into an engine command, or null to ignore. */
function toCommand(address, args) {
  let path = address.toLowerCase();
  for (const prefix of ['/timer/', '/countdown/', '/uniqueav/', '/']) {
    if (path.startsWith(prefix)) { path = path.slice(prefix.length); break; }
  }
  const command = path.replace(/\//g, '-');
  const arg = args[0];
  const usesArg = ARG_COMMANDS.has(command);
  if (!usesArg && arg !== undefined && isFinite(Number(arg)) && Number(arg) === 0) return null;
  return { command, argument: usesArg ? arg ?? null : null };
}

class OSCServer {
  constructor(onCommand) {
    this.onCommand = onCommand;
    this.socket = null;
    this.port = null;
    this.status = 'Off';
  }

  start(port) {
    this.stop();
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    sock.on('message', (buf) => {
      try {
        for (const m of parsePacket(buf)) {
          const c = toCommand(m.address, m.args);
          if (c) this.onCommand(c.command, c.argument);
        }
      } catch { /* ignore malformed packets */ }
    });
    sock.on('error', (e) => {
      this.status = `Error: ${e.code === 'EADDRINUSE' ? `UDP ${port} is in use by another app` : e.message}`;
    });
    sock.on('listening', () => { this.status = `Listening on UDP ${port}`; });
    try {
      sock.bind(port);
      this.socket = sock;
      this.port = port;
      this.status = 'Starting…';
    } catch (e) {
      this.status = `Error: ${e.message}`;
    }
  }

  stop() {
    if (this.socket) { try { this.socket.close(); } catch { /* already closed */ } }
    this.socket = null;
    this.port = null;
    this.status = 'Off';
  }
}

module.exports = { OSCServer, parseMessage, parsePacket, toCommand };

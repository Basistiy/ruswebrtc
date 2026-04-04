const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || '0.0.0.0';
const PUBLIC_DIR = path.join(__dirname, 'public');
const TURN_URLS = (process.env.TURN_URLS || '')
  .split(',')
  .map((v) => v.trim())
  .filter(Boolean);
const TURN_USERNAME = process.env.TURN_USERNAME || '';
const TURN_CREDENTIAL = process.env.TURN_CREDENTIAL || '';

function buildRtcConfig(reqHost) {
  const hostWithoutPort = (reqHost || 'localhost').split(':')[0];
  const turnUrls = TURN_URLS.length > 0 ? TURN_URLS : [`turn:${hostWithoutPort}:3478`];
  return {
    iceServers: [
      {
        urls: turnUrls,
        username: TURN_USERNAME,
        credential: TURN_CREDENTIAL,
      },
    ],
  };
}

const server = http.createServer((req, res) => {
  const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  log('http.request', {
    method: req.method,
    url: req.url,
    ip: req.socket?.remoteAddress || 'unknown',
    ua: req.headers['user-agent'] || 'unknown',
  });

  if (parsedUrl.pathname === '/rtc-config') {
    const rtcConfig = buildRtcConfig(req.headers.host);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(rtcConfig));
    return;
  }

  const requestPath = parsedUrl.pathname === '/' ? '/index.html' : parsedUrl.pathname;
  const filePath = path.join(PUBLIC_DIR, requestPath);

  if (!filePath.startsWith(PUBLIC_DIR)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }

    const ext = path.extname(filePath);
    const contentType =
      ext === '.html'
        ? 'text/html'
        : ext === '.js'
        ? 'application/javascript'
        : ext === '.css'
        ? 'text/css'
        : 'text/plain';

    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
});

const wss = new WebSocketServer({ server, path: '/ws' });

server.on('upgrade', (req) => {
  log('http.upgrade', {
    url: req.url,
    ip: req.socket?.remoteAddress || 'unknown',
    ua: req.headers['user-agent'] || 'unknown',
  });
});

const peers = new Map();
let nextPeerId = 1;

function log(event, meta = {}) {
  const details = Object.entries(meta)
    .map(([k, v]) => `${k}=${JSON.stringify(v)}`)
    .join(' ');
  console.log(`[${new Date().toISOString()}] ${event}${details ? ` ${details}` : ''}`);
}

function sendJson(ws, payload) {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function oppositePeer(peerId) {
  for (const [id, ws] of peers.entries()) {
    if (id !== peerId && ws.readyState === ws.OPEN) {
      return ws;
    }
  }
  return null;
}

function broadcastCount() {
  const count = peers.size;
  for (const ws of peers.values()) {
    sendJson(ws, { type: 'peers', count });
  }
}

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => {
    ws.isAlive = true;
  });

  const ip = ws._socket?.remoteAddress || 'unknown';
  if (peers.size >= 2) {
    log('connection.rejected', { reason: 'room_full', ip });
    sendJson(ws, { type: 'error', message: 'Room is full (2 peers max).' });
    ws.close(1000, 'Room full');
    return;
  }

  const peerId = String(nextPeerId++);
  peers.set(peerId, ws);
  log('connection.open', { peerId, ip, peers: peers.size });

  sendJson(ws, { type: 'welcome', peerId });
  broadcastCount();

  ws.on('message', (raw) => {
    let message;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      log('message.invalid_json', { peerId });
      sendJson(ws, { type: 'error', message: 'Invalid JSON message.' });
      return;
    }

    if (!message || typeof message.type !== 'string') {
      log('message.malformed', { peerId, message });
      sendJson(ws, { type: 'error', message: 'Malformed signaling message.' });
      return;
    }

    log('message.in', { peerId, type: message.type });

    if (message.type === 'offer' || message.type === 'answer' || message.type === 'candidate') {
      const other = oppositePeer(peerId);
      if (!other) {
        log('message.relay_failed', { peerId, type: message.type, reason: 'no_other_peer' });
        sendJson(ws, {
          type: 'error',
          message: 'No second peer connected yet.',
        });
        return;
      }

      const targetPeerId = [...peers.entries()].find(([, sock]) => sock === other)?.[0] || 'unknown';
      log('message.relay', { fromPeerId: peerId, toPeerId: targetPeerId, type: message.type });
      sendJson(other, {
        type: message.type,
        payload: message.payload,
      });
    }
  });

  ws.on('close', () => {
    peers.delete(peerId);
    log('connection.close', { peerId, peers: peers.size });
    broadcastCount();

    const other = oppositePeer(peerId);
    if (other) {
      sendJson(other, {
        type: 'peer-left',
      });
    }
  });

  ws.on('error', (error) => {
    log('connection.error', { peerId, error: error.message });
  });
});

const heartbeatInterval = setInterval(() => {
  for (const [peerId, ws] of peers.entries()) {
    if (ws.isAlive === false) {
      log('connection.terminate_stale', { peerId });
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    ws.ping();
  }
}, 15000);

wss.on('close', () => {
  clearInterval(heartbeatInterval);
});

server.listen(PORT, HOST, () => {
  log('server.listen', { host: HOST, port: Number(PORT), localhostUrl: `http://localhost:${PORT}` });
  log('turn.config', {
    turnUrls: TURN_URLS.length > 0 ? TURN_URLS : ['turn:<request-host>:3478'],
    hasUsername: Boolean(TURN_USERNAME),
    hasCredential: Boolean(TURN_CREDENTIAL),
  });

  const interfaces = os.networkInterfaces();
  for (const [name, addresses] of Object.entries(interfaces)) {
    if (!Array.isArray(addresses)) continue;
    for (const addr of addresses) {
      if (addr.family === 'IPv4' && !addr.internal) {
        log('server.lan_url', { iface: name, url: `http://${addr.address}:${PORT}` });
      }
    }
  }
});

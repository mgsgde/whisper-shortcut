// WhisperShortcut opt-in usage statistics endpoint.
//
// Receives anonymous counts from apps whose user turned "Share anonymous usage statistics" on,
// and writes each validated ping as one JSON line to stdout. Cloud Logging picks the line up and
// a log sink moves it to BigQuery. Nothing else is stored:
//
// - no IP, no user agent, no headers are ever logged (the Cloud Run request log for this service
//   is excluded in Cloud Logging — see deploy.sh);
// - the client IP is only held in memory for the rate limit below and forgotten within the hour.
//
// No dependencies on purpose: this file, sanitize.js and rate-limit.js are the whole
// server, so anyone can check what happens to the data.
'use strict';

const http = require('http');
const { sanitize, toStorage } = require('./sanitize');
const { clientKey, recordHit } = require('./rate-limit');
const schema = require('./schema.json');

const PORT = Number(process.env.PORT) || 8080;

// Guards against a client stuck in a send loop, not against attackers: the data is anonymous
// counts, so abuse can pollute but never leak anything.
const hits = new Map();
setInterval(() => hits.clear(), 60 * 60 * 1000).unref();

function reply(res, status) {
  res.writeHead(status, { 'Cache-Control': 'no-store' });
  res.end();
}

const server = http.createServer((req, res) => {
  // Not /healthz: Cloud Run's front end reserves paths ending in "z" and answers them itself (404).
  if (req.method === 'GET' && req.url === '/health') return reply(res, 204);
  if (req.method !== 'POST' || req.url !== '/v1/ping') return reply(res, 404);
  if (!String(req.headers['content-type'] || '').startsWith('application/json')) return reply(res, 400);

  const key = clientKey(req);
  if (recordHit(hits, key).limited) return reply(res, 429);

  let size = 0;
  const chunks = [];
  let aborted = false;
  req.on('data', (chunk) => {
    size += chunk.length;
    if (size > schema.maxBytes) {
      aborted = true;
      reply(res, 413);
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });
  req.on('end', () => {
    if (aborted) return;
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch {
      return reply(res, 400);
    }
    const doc = sanitize(body);
    if (!doc) return reply(res, 400);
    // One structured line; Cloud Logging stores it as jsonPayload.telemetry.
    process.stdout.write(JSON.stringify({ telemetry: toStorage(doc) }) + '\n');
    reply(res, 204);
  });
});

server.listen(PORT, () => {
  process.stdout.write(JSON.stringify({ message: `telemetry listening on ${PORT}` }) + '\n');
});

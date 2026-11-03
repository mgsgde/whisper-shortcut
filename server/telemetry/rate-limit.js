// In-memory hourly rate limit for /v1/ping.
//
// The client IP is held only for this window and is never logged. Cloud Run
// overwrites X-Forwarded-For, so the leftmost entry is the real client there.
// The map cap is for a loop that presents a new key on every request: without
// it `hits` grows without bound inside the hour on a 128 MiB instance.
'use strict';

const RATE_LIMIT_PER_HOUR = 60;
const MAX_TRACKED_CLIENTS = 10_000;

function clientKey(req) {
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string') {
    const first = forwarded.split(',')[0].trim();
    if (first) return first;
  }
  return req.socket.remoteAddress || '';
}

function recordHit(hits, key, limit = RATE_LIMIT_PER_HOUR, maxKeys = MAX_TRACKED_CLIENTS) {
  if (!hits.has(key) && hits.size >= maxKeys) {
    return { limited: true, count: 0 };
  }
  const count = (hits.get(key) || 0) + 1;
  hits.set(key, count);
  return { limited: count > limit, count };
}

module.exports = { clientKey, recordHit, RATE_LIMIT_PER_HOUR, MAX_TRACKED_CLIENTS };

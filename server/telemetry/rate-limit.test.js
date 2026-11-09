'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { clientKey, recordHit, RATE_LIMIT_PER_HOUR, MAX_TRACKED_CLIENTS } = require('./rate-limit');

test('clientKey uses the leftmost X-Forwarded-For hop (Cloud Run overwrites the header)', () => {
  assert.strictEqual(
    clientKey({ headers: { 'x-forwarded-for': '203.0.113.9, 169.254.1.1' }, socket: {} }),
    '203.0.113.9'
  );
  assert.strictEqual(
    clientKey({ headers: {}, socket: { remoteAddress: '127.0.0.1' } }),
    '127.0.0.1'
  );
});

test('recordHit rate-limits one key after the hourly cap', () => {
  const hits = new Map();
  for (let i = 0; i < RATE_LIMIT_PER_HOUR; i++) {
    assert.strictEqual(recordHit(hits, 'a').limited, false);
  }
  assert.strictEqual(recordHit(hits, 'a').limited, true);
  assert.strictEqual(recordHit(hits, 'b').limited, false);
});

test('recordHit refuses a new key once the map is full', () => {
  const hits = new Map();
  const max = 3;
  assert.strictEqual(recordHit(hits, 'a', RATE_LIMIT_PER_HOUR, max).limited, false);
  assert.strictEqual(recordHit(hits, 'b', RATE_LIMIT_PER_HOUR, max).limited, false);
  assert.strictEqual(recordHit(hits, 'c', RATE_LIMIT_PER_HOUR, max).limited, false);
  assert.strictEqual(recordHit(hits, 'd', RATE_LIMIT_PER_HOUR, max).limited, true);
  assert.strictEqual(hits.size, max);
  assert.strictEqual(recordHit(hits, 'a', RATE_LIMIT_PER_HOUR, max).limited, false);
});

test('MAX_TRACKED_CLIENTS is well below a 128 MiB heap of empty keys', () => {
  assert.ok(MAX_TRACKED_CLIENTS >= 1_000);
  assert.ok(MAX_TRACKED_CLIENTS <= 100_000);
});

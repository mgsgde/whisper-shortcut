'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { sanitize, toStorage } = require('./sanitize');

const base = { v: 1, app: '8.27', build: 'appstore', os: '26', cohortWeek: '2026-W40', dayIndex: 0 };

test('daily ping keeps known keys and drops unknown ones', () => {
  const doc = sanitize({
    ...base,
    kind: 'daily',
    secret: 'transcript text',
    setup: { providers: ['gemini', 'evil'], autoPaste: true, note: 'x' },
    counts: { 'dictation.completed': 3, 'dictation.hello': 1, 'bogus.completed': 2, 'chat.chatRetry': 0 },
    errors: { 'dictation.network': 1, 'dictation.Some message': 1 },
    models: { transcription: { 'gemini-3.5-flash': 3, 'Has Spaces': 1 }, other: { x: 1 } },
  });
  assert.deepStrictEqual(doc, {
    ...base,
    kind: 'daily',
    setup: { providers: ['gemini'], autoPaste: true },
    counts: { 'dictation.completed': 3 },
    errors: { 'dictation.network': 1 },
    models: { transcription: { 'gemini-3.5-flash': 3 } },
  });
  assert.ok(!JSON.stringify(doc).includes('transcript text'));
});

test('milestone keeps milestone and error class only', () => {
  assert.deepStrictEqual(
    sanitize({ ...base, kind: 'milestone', milestone: 'activation.firstDictationFailed', errorClass: 'invalidKey', counts: { 'dictation.completed': 1 } }),
    { ...base, kind: 'milestone', milestone: 'activation.firstDictationFailed', errorClass: 'invalidKey' }
  );
});

test('rejects malformed envelopes', () => {
  assert.strictEqual(sanitize(null), null);
  assert.strictEqual(sanitize({ ...base, kind: 'daily', v: 2 }), null);
  assert.strictEqual(sanitize({ ...base, kind: 'daily', app: 'hello' }), null);
  assert.strictEqual(sanitize({ ...base, kind: 'daily', build: 'beta' }), null);
  assert.strictEqual(sanitize({ ...base, kind: 'daily', cohortWeek: 'yesterday' }), null);
  assert.strictEqual(sanitize({ ...base, kind: 'daily', dayIndex: -1 }), null);
  assert.strictEqual(sanitize({ ...base, kind: 'milestone', milestone: 'made.up' }), null);
  assert.strictEqual(sanitize({ ...base, kind: 'weekly' }), null);
});

test('rejects non-integer and huge counts', () => {
  const doc = sanitize({ ...base, kind: 'daily', counts: { 'dictation.completed': 1.5, 'prompt.completed': 1e9, 'chat.completed': 2 } });
  assert.deepStrictEqual(doc.counts, { 'chat.completed': 2 });
});

test('storage shape turns keyed maps into rows', () => {
  const stored = toStorage({ ...base, kind: 'daily', counts: { 'dictation.completed': 3 }, errors: { 'chat.network': 1 }, models: { chat: { custom: 2 } } });
  assert.deepStrictEqual(stored.counts, [{ key: 'dictation.completed', n: 3 }]);
  assert.deepStrictEqual(stored.errors, [{ key: 'chat.network', n: 1 }]);
  assert.deepStrictEqual(stored.models, [{ kind: 'chat', id: 'custom', n: 2 }]);
});

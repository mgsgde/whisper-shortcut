// Turns an untrusted ping into the document that gets stored — or null if it is not a ping.
//
// Everything is rebuilt from the schema's closed sets: an unknown key is dropped, never copied,
// so a client bug that puts user text somewhere cannot reach storage through this function.
'use strict';

const schema = require('./schema.json');

const modelIdRe = new RegExp(schema.modelIdPattern);
const appRe = /^\d{1,4}(\.\d{1,4}){0,3}$/;
const osRe = /^\d{1,3}$/;
const cohortRe = /^(\d{4}-W\d{2}|pre-telemetry)$/;
const MAX_COUNT = 100000;

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isCount = (v) => Number.isInteger(v) && v >= 0 && v <= MAX_COUNT;

function pickCounts(input, keyOk) {
  if (!isObject(input)) return undefined;
  const out = {};
  for (const [k, v] of Object.entries(input)) {
    if (keyOk(k) && isCount(v) && v > 0) out[k] = v;
  }
  return Object.keys(out).length ? out : undefined;
}

function areaKey(k, names) {
  const dot = k.indexOf('.');
  if (dot < 0) return false;
  return schema.areas.includes(k.slice(0, dot)) && names.includes(k.slice(dot + 1));
}

function sanitize(body) {
  if (!isObject(body) || body.v !== schema.version) return null;
  if (typeof body.app !== 'string' || !appRe.test(body.app)) return null;
  if (!schema.builds.includes(body.build)) return null;
  if (typeof body.os !== 'string' || !osRe.test(body.os)) return null;
  if (typeof body.cohortWeek !== 'string' || !cohortRe.test(body.cohortWeek)) return null;
  if (!Number.isInteger(body.dayIndex) || body.dayIndex < 0 || body.dayIndex > 3650) return null;
  if (!schema.kinds.includes(body.kind)) return null;

  const doc = {
    v: body.v,
    app: body.app,
    build: body.build,
    os: body.os,
    cohortWeek: body.cohortWeek,
    dayIndex: body.dayIndex,
    kind: body.kind,
  };

  if (body.kind === 'milestone') {
    if (!schema.milestones.includes(body.milestone)) return null;
    doc.milestone = body.milestone;
    if (schema.errorClasses.includes(body.errorClass)) doc.errorClass = body.errorClass;
    return doc;
  }

  if (isObject(body.setup)) {
    const setup = {};
    if (Array.isArray(body.setup.providers)) {
      setup.providers = [...new Set(body.setup.providers.filter((p) => schema.providers.includes(p)))];
    }
    for (const flag of schema.setupFlags) {
      if (typeof body.setup[flag] === 'boolean') setup[flag] = body.setup[flag];
    }
    doc.setup = setup;
  }

  const counts = pickCounts(body.counts, (k) => areaKey(k, schema.countNames));
  if (counts) doc.counts = counts;
  const errors = pickCounts(body.errors, (k) => areaKey(k, schema.errorClasses));
  if (errors) doc.errors = errors;

  if (isObject(body.models)) {
    const models = {};
    for (const kind of schema.modelKinds) {
      const picked = pickCounts(body.models[kind], (k) => modelIdRe.test(k));
      if (!picked) continue;
      const top = Object.entries(picked)
        .sort((a, b) => b[1] - a[1])
        .slice(0, schema.maxModelsPerKind);
      models[kind] = Object.fromEntries(top);
    }
    if (Object.keys(models).length) doc.models = models;
  }

  return doc;
}

// Storage shape for the BigQuery log sink. The wire format keys counts by name
// ("dictation.completed", model ids), but a log sink turns every distinct key into its own column —
// with dots rewritten — so the table schema would grow with every model id. Stored as rows instead.
function toStorage(doc) {
  const out = { ...doc };
  const rows = (obj) => Object.entries(obj).map(([key, n]) => ({ key, n }));
  if (doc.counts) out.counts = rows(doc.counts);
  if (doc.errors) out.errors = rows(doc.errors);
  if (doc.models) {
    out.models = Object.entries(doc.models).flatMap(([kind, ids]) =>
      Object.entries(ids).map(([id, n]) => ({ kind, id, n }))
    );
  }
  return out;
}

module.exports = { sanitize, toStorage };

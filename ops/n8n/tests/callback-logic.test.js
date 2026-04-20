#!/usr/bin/env node
// callback-logic.test.js
//
// Standalone test of the Verify+Route JS logic used in the n8n ai-review-callback
// workflow. Covers: Ed25519 signature verification, timestamp replay protection,
// PING → pong routing, button-click custom_id parsing, malformed input rejection.
//
// Keeps the callback's decision tree testable without needing a live n8n instance
// or real Discord signatures. Runs in CI via: node ops/n8n/tests/callback-logic.test.js
//
// IMPORTANT: The runCallback() body below MUST stay in sync with the jsCode of the
// "Verify + Route" node in ops/n8n/workflows/ai-review-callback.json. If you change
// the workflow JS, update this file AND the cross-check script.

const crypto = require('crypto');
const { generateKeyPairSync, sign } = require('crypto');

const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const PUB_HEX = publicKey.export({ type: 'spki', format: 'der' }).slice(-32).toString('hex');

function signRequest(body, tsOffsetSec = 0) {
  const ts = String(Math.floor(Date.now() / 1000) + tsOffsetSec);
  const raw = typeof body === 'string' ? body : JSON.stringify(body);
  const sig = sign(null, Buffer.from(ts + raw, 'utf8'), privateKey).toString('hex');
  return { ts, raw, sig };
}

function runCallback({ rawBody, signature, timestamp, pubKey, targetRepo = 'X/Y' }) {
  const MAX_TIMESTAMP_SKEW_SEC = 300;
  const VALID_ACTIONS = new Set(['approve', 'fix', 'manual']);

  let body = {};
  try { body = JSON.parse(rawBody || '{}'); } catch (e) {}

  const tsNum = parseInt(timestamp, 10);
  const nowSec = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(tsNum) || Math.abs(nowSec - tsNum) > MAX_TIMESTAMP_SKEW_SEC) {
    return { _route: 'reject', _response: { error: 'invalid_timestamp' }, _status: 401 };
  }

  let verifyOk = false;
  try {
    if (pubKey && signature && timestamp && rawBody) {
      const pub = Buffer.from(pubKey, 'hex');
      const sig = Buffer.from(signature, 'hex');
      const msg = Buffer.from(timestamp + rawBody, 'utf8');
      verifyOk = crypto.verify(null, msg, { key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), pub]), format: 'der', type: 'spki' }, sig);
    }
  } catch (err) { /* verifyOk stays false */ }

  if (!verifyOk) return { _route: 'reject', _response: { error: 'invalid_signature' }, _status: 401 };

  if (body.type === 1) return { _route: 'pong', _response: { type: 1 }, _status: 200 };

  if (body.type === 3) {
    const customId = body.data?.custom_id ?? '';
    const [a, p] = customId.split(':');
    const action = (a ?? '').toLowerCase().trim();
    const prNumber = parseInt(p ?? '', 10);
    const userId = body.member?.user?.id ?? body.user?.id ?? '';
    if (!VALID_ACTIONS.has(action) || !Number.isFinite(prNumber) || prNumber <= 0) {
      return { _route: 'reject', _response: { type: 4, data: { content: `Unknown action \`${customId}\``, flags: 64 } }, _status: 200 };
    }
    return { _route: 'dispatch', _response: { type: 6 }, _status: 200, _dispatch: { action, pr_number: prNumber, user_id: userId, target_repo: targetRepo } };
  }

  return { _route: 'reject', _response: { error: 'unknown_type' }, _status: 400 };
}

const tests = [
  {
    name: 'valid PING → pong',
    run: () => {
      const { ts, raw, sig } = signRequest({ type: 1 });
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'pong' && r._response.type === 1 && r._status === 200
  },
  {
    name: 'invalid signature → 401',
    run: () => {
      const { ts, raw } = signRequest({ type: 1 });
      return runCallback({ rawBody: raw, signature: '00'.repeat(64), timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'reject' && r._response.error === 'invalid_signature' && r._status === 401
  },
  {
    name: 'replay attack (old timestamp) → 401 invalid_timestamp',
    run: () => {
      const { ts, raw, sig } = signRequest({ type: 1 }, -400);
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'reject' && r._response.error === 'invalid_timestamp' && r._status === 401
  },
  {
    name: 'future timestamp (>5min) → 401 invalid_timestamp',
    run: () => {
      const { ts, raw, sig } = signRequest({ type: 1 }, 400);
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'reject' && r._response.error === 'invalid_timestamp'
  },
  {
    name: 'valid button click approve:42 → dispatch',
    run: () => {
      const payload = { type: 3, data: { custom_id: 'approve:42' }, member: { user: { id: 'U123' } }, id: 'I1', token: 'T1' };
      const { ts, raw, sig } = signRequest(payload);
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX, targetRepo: 'EtroxTaran/ai-portal' });
    },
    expect: (r) => r._route === 'dispatch' && r._response.type === 6 && r._dispatch.action === 'approve' && r._dispatch.pr_number === 42 && r._dispatch.user_id === 'U123' && r._dispatch.target_repo === 'EtroxTaran/ai-portal'
  },
  {
    name: 'valid button click fix:1 (DM, user instead of member) → dispatch',
    run: () => {
      const payload = { type: 3, data: { custom_id: 'fix:1' }, user: { id: 'U456' } };
      const { ts, raw, sig } = signRequest(payload);
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'dispatch' && r._dispatch.action === 'fix' && r._dispatch.pr_number === 1 && r._dispatch.user_id === 'U456'
  },
  {
    name: 'valid button click MANUAL:99 (case-insensitive) → dispatch',
    run: () => {
      const payload = { type: 3, data: { custom_id: 'MANUAL:99' }, user: { id: 'U' } };
      const { ts, raw, sig } = signRequest(payload);
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'dispatch' && r._dispatch.action === 'manual' && r._dispatch.pr_number === 99
  },
  {
    name: 'malformed custom_id (bogus:abc) → ephemeral error (type:4 flags:64)',
    run: () => {
      const payload = { type: 3, data: { custom_id: 'bogus:abc' }, user: { id: 'U' } };
      const { ts, raw, sig } = signRequest(payload);
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'reject' && r._response.type === 4 && r._response.data.flags === 64
  },
  {
    name: 'unknown action (delete:5) → ephemeral error',
    run: () => {
      const payload = { type: 3, data: { custom_id: 'delete:5' }, user: { id: 'U' } };
      const { ts, raw, sig } = signRequest(payload);
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'reject' && r._response.type === 4
  },
  {
    name: 'negative pr_number (approve:-1) → ephemeral error',
    run: () => {
      const payload = { type: 3, data: { custom_id: 'approve:-1' }, user: { id: 'U' } };
      const { ts, raw, sig } = signRequest(payload);
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'reject' && r._response.type === 4
  },
  {
    name: 'unknown interaction type (99) → 400',
    run: () => {
      const { ts, raw, sig } = signRequest({ type: 99 });
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: PUB_HEX });
    },
    expect: (r) => r._route === 'reject' && r._response.error === 'unknown_type' && r._status === 400
  },
  {
    name: 'empty body → invalid_signature',
    run: () => runCallback({ rawBody: '', signature: '00'.repeat(64), timestamp: String(Math.floor(Date.now() / 1000)), pubKey: PUB_HEX }),
    expect: (r) => r._route === 'reject' && r._response.error === 'invalid_signature'
  },
  {
    name: 'wrong pubkey → invalid_signature',
    run: () => {
      const { publicKey: otherPub } = generateKeyPairSync('ed25519');
      const otherPubHex = otherPub.export({ type: 'spki', format: 'der' }).slice(-32).toString('hex');
      const { ts, raw, sig } = signRequest({ type: 1 });
      return runCallback({ rawBody: raw, signature: sig, timestamp: ts, pubKey: otherPubHex });
    },
    expect: (r) => r._route === 'reject' && r._response.error === 'invalid_signature'
  },
];

let pass = 0, fail = 0;
for (const t of tests) {
  const result = t.run();
  const ok = t.expect(result);
  console.log(`${ok ? '[PASS]' : '[FAIL]'} ${t.name}`);
  if (!ok) { console.log('   got:', JSON.stringify(result)); fail++; } else { pass++; }
}
console.log(`\n${pass}/${pass + fail} tests passed`);
process.exit(fail === 0 ? 0 : 1);

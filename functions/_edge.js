/**
 * TowOS edge — shared logic for the Pages Functions under /api.
 *
 * Why this exists (2026-09-19, speed Phase 2): every dash tap paid a ~2.6s
 * Apps Script wake-up before any work happened, so even a cached dashInit
 * took 2.6s on the phone. This puts Cloudflare KV in front of the READ
 * calls: a hit answers from the edge in tens of milliseconds, a miss goes
 * to Apps Script once and is kept for a short TTL. WRITES always go to
 * Apps Script; when the server answers a Lot write with the fresh record
 * (25 v1.2 returns { detail, lot }), that record is written straight into
 * KV so the next read is fresh without another Google hop.
 *
 * Auth never moves to the edge. A cached read is served only to a key that
 * Apps Script has already accepted: the first request per key passes
 * through, and only an ok:true answer marks that key trusted (1h). An
 * invalid key gets ok:false from the server and never sees the cache.
 * dashInit is cached PER KEY because its payload carries me/canSettings.
 *
 * Invalidation is by generation: each cache group has gen:<group> in KV and
 * the gen is part of every cache key, so a write bumps one number and the
 * whole group is stale at once. /api/bust (bearer EDGE_SECRET) does the
 * same for Apps Script-side writes. KV is eventually consistent (~60s
 * across POPs); one operator on one phone sees his own writes immediately
 * because write-through lands the new record under the new gen.
 */

export const READ_FNS = {
  // fn: [group, ttlSeconds, perKey]
  // KV refuses expirationTtl under 60s (the put throws, silently, and the
  // entry is never written -- dashInit never hit until this was 60).
  dashInit:       ['board', 60, true],
  dashDay:        ['board', 60, false],
  dashShifts:     ['board', 90, false],
  dashApplicants: ['appl', 300, false],
  dashApplicant:  ['appl', 300, false],
  dashConfigList: ['config', 600, false],
  dashImpounds:   ['lot', 300, false],
  dashImpound:    ['lot', 300, false],
  dashAuction:    ['lot', 300, false]
};

export const GROUPS = ['board', 'appl', 'config', 'lot', 'auth'];

/** Which arg is the caller key. dashInit(k, force) is the one exception to "key last". */
const KEY_POS = { dashInit: 0 };

/** Which group(s) a write invalidates. Anything unknown bumps everything but auth. */
export function groupsForWrite(fn) {
  if (/Impound|Auction/.test(fn)) return ['lot'];         // the board does not show the lot
  if (/Applicant|Hire/.test(fn)) return ['appl', 'board']; // a hire changes the roster
  if (/Config/.test(fn)) return ['config', 'board'];
  if (/Punch|Shift|Schedule|Exception|Driver|Alias/.test(fn)) return ['board'];
  return ['board', 'appl', 'config', 'lot'];   // a function this file has not met: assume the worst
}

export async function sha256(s) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(s)));
  return Array.from(new Uint8Array(buf)).map(b => ('0' + b.toString(16)).slice(-2)).join('');
}

export function keyOf(fn, args) {
  if (!Array.isArray(args) || !args.length) return '';
  const pos = KEY_POS.hasOwnProperty(fn) ? KEY_POS[fn] : args.length - 1;
  return args[pos] == null ? '' : String(args[pos]);
}

export function argsSansKey(fn, args) {
  if (!Array.isArray(args) || !args.length) return [];
  const pos = KEY_POS.hasOwnProperty(fn) ? KEY_POS[fn] : args.length - 1;
  return args.filter((_, i) => i !== pos);
}

/**
 * Current generation of a group. KV reads are cached at the POP for ~60s, so
 * right after a write the writer's own reads could still see the OLD gen and
 * hit a stale entry. The dash therefore sends back the gens it was last told
 * (egen=...), and the larger of the two wins: the writer is always current,
 * another device is at worst ~60s behind, and a made-up huge hint can only
 * cause misses, never a stale hit.
 */
export async function getGen(env, group, hints) {
  const v = await env.EDGE.get('gen:' + group);
  const kv = v || '0';
  const h = hints && hints[group] != null ? String(hints[group]) : '0';
  return (Number(h) > Number(kv)) ? h : kv;
}

export async function bumpGens(env, groups) {
  const out = {};
  for (const g of groups) {
    if (GROUPS.indexOf(g) < 0) continue;
    const next = String(Date.now());
    await env.EDGE.put('gen:' + g, next);
    out[g] = next;
  }
  return out;
}

export async function cacheKey(env, fn, args, keyHash, hints) {
  const spec = READ_FNS[fn];
  const gen = await getGen(env, spec[0], hints);
  const body = JSON.stringify(argsSansKey(fn, args));
  const h = await sha256(body);
  return 'c:' + spec[0] + ':' + gen + ':' + fn + ':' + h.slice(0, 24) + (spec[2] ? ':' + keyHash.slice(0, 24) : '');
}

export async function isTrusted(env, keyHash) {
  const gen = await getGen(env, 'auth');
  return !!(await env.EDGE.get('auth:' + gen + ':' + keyHash));
}

export async function markTrusted(env, keyHash) {
  const gen = await getGen(env, 'auth');
  await env.EDGE.put('auth:' + gen + ':' + keyHash, '1', { expirationTtl: 3600 });
}

/** Apps Script, with the same query string the dash has always sent. 25s cap. */
export async function upstream(env, qs) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 25000);
  try {
    const r = await fetch(env.TOWOS_API_URL + '?' + qs, { redirect: 'follow', signal: ctl.signal, headers: { 'accept': 'application/json,text/plain' } });
    const text = await r.text();
    return { status: r.status, text };
  } finally {
    clearTimeout(timer);
  }
}

export function json(obj, status, extraHeaders) {
  const h = Object.assign({ 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }, extraHeaders || {});
  return new Response(JSON.stringify(obj), { status: status || 200, headers: h });
}

/**
 * Write-through after a Lot write: 25 v1.2 answers with { detail, lot }.
 * Bump the lot gen first so every older entry is dead, then store the two
 * fresh payloads under the new gen, so the next tap is a hit AND current.
 */
export async function writeThroughLot(env, data) {
  if (!data) return false;
  if (data.auction && data.auction.auction && data.auction.vehicles) return writeThroughAuction(env, data.auction);
  if (!data.detail || !data.lot) return false;
  const gens = await bumpGens(env, ['lot']);
  const gen = gens.lot;
  const lotSpec = READ_FNS.dashImpounds, detSpec = READ_FNS.dashImpound;
  const hLot = await sha256(JSON.stringify([]));
  const hDet = await sha256(JSON.stringify([String(data.detail.id)]));
  const now = Date.now();
  await env.EDGE.put('c:lot:' + gen + ':dashImpounds:' + hLot.slice(0, 24), JSON.stringify({ ok: true, data: data.lot, at: now }), { expirationTtl: lotSpec[1] });
  await env.EDGE.put('c:lot:' + gen + ':dashImpound:' + hDet.slice(0, 24), JSON.stringify({ ok: true, data: data.detail, at: now }), { expirationTtl: detSpec[1] });
  return gens;   // truthy: the new gens, for the caller to carry forward
}

/**
 * An auction write (29 v1.0) answers with the whole redrawn screen. Store it
 * under the new lot gen as the answer to dashAuction('') so the dash's own
 * refetch is a HIT instead of a 15s rebuild on a busy morning -- which is
 * what killed the screen mid-auction on 9/22. The lot list itself is left to
 * the prewarm; the auction is the thing on screen.
 */
export async function writeThroughAuction(env, view) {
  const gens = await bumpGens(env, ['lot']);
  const h = await sha256(JSON.stringify(['']));
  await env.EDGE.put('c:lot:' + gens.lot + ':dashAuction:' + h.slice(0, 24), JSON.stringify({ ok: true, data: view, at: Date.now() }), { expirationTtl: READ_FNS.dashAuction[1] });
  return gens;
}

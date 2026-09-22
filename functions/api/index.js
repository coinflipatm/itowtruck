/**
 * GET /api?api=1&fn=<name>&args=<json array>  — same contract as Apps Script.
 * Reads in READ_FNS are served from KV when the key is trusted and the entry
 * is fresh; everything else passes through to Apps Script unchanged.
 * The envelope gains one field, edge: { hit, age_s | upstream_ms }, which the
 * dash's ?perf=1 pill shows. Nothing else about the shape changes.
 */
import { READ_FNS, sha256, keyOf, cacheKey, isTrusted, markTrusted, upstream, json, writeThroughLot, bumpGens, groupsForWrite, getGen } from '../_edge.js';

/**
 * Refetch the reads a write just invalidated, for the writer's key, and cache
 * them. In parallel: each is its own Apps Script execution, and run one after
 * another on a slow morning they blow past the ~30s waitUntil budget and the
 * later ones never land (9/22). skipInit: the login seeding has just cached
 * dashInit itself, no point fetching it again.
 */
async function prewarm(env, groups, key, keyHash, hints, skip) {
  skip = skip || {};
  const plan = [];
  if (groups.indexOf('board') >= 0) { plan.push(['dashShifts', [key]]); if (!skip.init) plan.push(['dashInit', [key, 0]]); }
  if (groups.indexOf('lot') >= 0) { plan.push(['dashImpounds', [key]]); if (!skip.auction) plan.push(['dashAuction', ['', key]]); }
  if (groups.indexOf('appl') >= 0) plan.push(['dashApplicants', [key]]);
  if (groups.indexOf('config') >= 0) plan.push(['dashConfigList', [key]]);
  await Promise.all(plan.map(async function ([fn, args]) {
    try {
      const qs = new URLSearchParams({ api: '1', fn: fn, args: JSON.stringify(args) }).toString();
      const r = await upstream(env, qs);
      let o = null; try { o = JSON.parse(r.text); } catch (e) {}
      if (!o || !o.ok) return;
      const ck = await cacheKey(env, fn, args, keyHash, hints);
      await env.EDGE.put(ck, JSON.stringify({ ok: true, data: o.data, at: Date.now() }), { expirationTtl: READ_FNS[fn][1] });
    } catch (e) {}
  }));
}

/** The gens the caller should carry forward, for the groups touched. */
async function gensFor(env, groups, hints) {
  const out = {};
  for (const g of groups) out[g] = await getGen(env, g, hints);
  return out;
}

export async function onRequestGet(context) {
  const { request, env } = context;
  const url = new URL(request.url);
  const fn = url.searchParams.get('fn') || '';
  let args = [];
  try { args = JSON.parse(url.searchParams.get('args') || '[]'); } catch (e) { args = []; }
  let hints = {};
  try { hints = JSON.parse(url.searchParams.get('egen') || '{}') || {}; } catch (e) { hints = {}; }
  if (!env || !env.EDGE || !env.TOWOS_API_URL) {
    const missing = [!env || !env.EDGE ? 'EDGE binding' : null, !env || !env.TOWOS_API_URL ? 'TOWOS_API_URL' : null].filter(Boolean);
    return json({ ok: false, error: 'edge not configured: missing ' + missing.join(', ') }, 503, { 'x-towos-edge': 'unconfigured' });
  }

  const key = keyOf(fn, args);
  const keyHash = key ? await sha256(key) : '';
  const spec = READ_FNS[fn];
  const force = fn === 'dashInit' && args.length > 1 && String(args[1]) === '1';
  const t0 = Date.now();

  // ---- read: try the cache
  if (spec && keyHash && !force) {
    let ck = null;
    try {
      if (await isTrusted(env, keyHash)) {
        ck = await cacheKey(env, fn, args, keyHash, hints);
        const hit = await env.EDGE.get(ck);
        if (hit) {
          const o = JSON.parse(hit);
          o.edge = { hit: true, age_s: Math.round((Date.now() - (o.at || Date.now())) / 1000), ms: Date.now() - t0, gens: await gensFor(env, [spec[0]], hints) };
          delete o.at;
          return json(o, 200, { 'x-towos-edge': 'hit' });
        }
      }
    } catch (e) { /* cache trouble is never an outage: fall through to upstream */ }

    const r = await upstream(env, url.searchParams.toString());
    let o;
    try { o = JSON.parse(r.text); } catch (e) { return new Response(r.text, { status: r.status, headers: { 'content-type': 'text/plain', 'x-towos-edge': 'miss-nonjson' } }); }
    if (!o || typeof o !== 'object') o = { ok: false, error: 'Empty answer from the server.' };
    if (o.ok) {
      try {
        await markTrusted(env, keyHash);
        if (!ck) ck = await cacheKey(env, fn, args, keyHash, hints);
        await env.EDGE.put(ck, JSON.stringify({ ok: true, data: o.data, at: Date.now() }), { expirationTtl: spec[1] });
        // Login seeding (9/22): the first dashInit miss is the moment he has just
        // signed in. Warm the other screens now, in the background, so his first
        // tap on Lot / People / Shifts is a HIT instead of a cold 10-20s read.
        if (fn === 'dashInit') context.waitUntil(prewarm(env, ['board', 'lot', 'appl'], key, keyHash, hints, { init: true }).catch(function () {}));
      } catch (e) {}
    }
    o.edge = { hit: false, upstream_ms: Date.now() - t0 };
    try { o.edge.gens = await gensFor(env, [spec[0]], hints); } catch (e) {}
    return json(o, 200, { 'x-towos-edge': 'miss' });
  }

  // ---- write (or an unknown / untrusted / forced read): pass through
  const r = await upstream(env, url.searchParams.toString());
  let o;
  try { o = JSON.parse(r.text); } catch (e) { return new Response(r.text, { status: r.status, headers: { 'content-type': 'text/plain', 'x-towos-edge': 'pass-nonjson' } }); }
  if (!o || typeof o !== 'object') o = { ok: false, error: 'Empty answer from the server.' };
  let gens = null;
  if (o.ok && keyHash) {
    try {
      await markTrusted(env, keyHash);
      if (spec) {
        // forced read: refresh the entry so the next unforced read is a hit
        const ck = await cacheKey(env, fn, args, keyHash, hints);
        await env.EDGE.put(ck, JSON.stringify({ ok: true, data: o.data, at: Date.now() }), { expirationTtl: spec[1] });
        gens = await gensFor(env, [spec[0]], hints);
      } else {
        const wt = await writeThroughLot(env, o.data);
        if (wt) {
          gens = wt;
          // an auction write bumped the lot gen but only stored the auction screen;
          // warm the lot list behind it so the Lot tab is a HIT when he goes back
          if (o.data && o.data.auction) context.waitUntil(prewarm(env, ['lot'], key, keyHash, gens, { auction: true }).catch(function () {}));
        }
        else {
          const groups = groupsForWrite(fn);
          gens = await bumpGens(env, groups);
          // Prewarm: the screens this write just invalidated are refetched for
          // this caller in the background, so his next tap is a HIT instead of
          // a 4-7s rebuild. Runs after the response is sent (waitUntil). The
          // new gens are passed as hints so the POP's cached old gen is ignored.
          context.waitUntil(prewarm(env, groups, key, keyHash, gens).catch(function () {}));
        }
      }
    } catch (e) {}
  }
  o.edge = { hit: false, upstream_ms: Date.now() - t0, pass: true };
  if (gens) o.edge.gens = gens;
  return json(o, 200, { 'x-towos-edge': 'pass' });
}

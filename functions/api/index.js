/**
 * GET /api?api=1&fn=<name>&args=<json array>  — same contract as Apps Script.
 * Reads in READ_FNS are served from KV when the key is trusted and the entry
 * is fresh; everything else passes through to Apps Script unchanged.
 * The envelope gains one field, edge: { hit, age_s | upstream_ms }, which the
 * dash's ?perf=1 pill shows. Nothing else about the shape changes.
 */
import { READ_FNS, sha256, keyOf, cacheKey, isTrusted, markTrusted, upstream, json, writeThroughLot, bumpGens, groupsForWrite } from '../_edge.js';

export async function onRequestGet(context) {
  const { request, env } = context;
  const url = new URL(request.url);
  const fn = url.searchParams.get('fn') || '';
  let args = [];
  try { args = JSON.parse(url.searchParams.get('args') || '[]'); } catch (e) { args = []; }
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
        ck = await cacheKey(env, fn, args, keyHash);
        const hit = await env.EDGE.get(ck);
        if (hit) {
          const o = JSON.parse(hit);
          o.edge = { hit: true, age_s: Math.round((Date.now() - (o.at || Date.now())) / 1000), ms: Date.now() - t0 };
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
        if (!ck) ck = await cacheKey(env, fn, args, keyHash);
        await env.EDGE.put(ck, JSON.stringify({ ok: true, data: o.data, at: Date.now() }), { expirationTtl: spec[1] });
      } catch (e) {}
    }
    o.edge = { hit: false, upstream_ms: Date.now() - t0 };
    return json(o, 200, { 'x-towos-edge': 'miss' });
  }

  // ---- write (or an unknown / untrusted / forced read): pass through
  const r = await upstream(env, url.searchParams.toString());
  let o;
  try { o = JSON.parse(r.text); } catch (e) { return new Response(r.text, { status: r.status, headers: { 'content-type': 'text/plain', 'x-towos-edge': 'pass-nonjson' } }); }
  if (!o || typeof o !== 'object') o = { ok: false, error: 'Empty answer from the server.' };
  if (o.ok && keyHash) {
    try {
      await markTrusted(env, keyHash);
      if (spec) {
        // forced read: refresh the entry so the next unforced read is a hit
        const ck = await cacheKey(env, fn, args, keyHash);
        await env.EDGE.put(ck, JSON.stringify({ ok: true, data: o.data, at: Date.now() }), { expirationTtl: spec[1] });
      } else if (!(await writeThroughLot(env, o.data))) {
        await bumpGens(env, groupsForWrite(fn));
      }
    } catch (e) {}
  }
  o.edge = { hit: false, upstream_ms: Date.now() - t0, pass: true };
  return json(o, 200, { 'x-towos-edge': 'pass' });
}

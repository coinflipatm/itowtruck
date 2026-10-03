/**
 * POST /api/bust   Authorization: Bearer <EDGE_SECRET>   body {"groups":["board"]}
 * Bumps the generation of each named group (board | appl | config | lot | auth),
 * which makes every cached entry in it stale at once. Apps Script calls this
 * from _dashBustBoot_ (Phase 2b) so an SMS-side punch does not wait out the
 * board TTL. GET /api/bust with the bearer reports the current gens.
 */
import { bumpGens, getGen, GROUPS, json, holdD1 } from '../_edge.js';

function authed(request, env) {
  const h = request.headers.get('authorization') || '';
  return !!(env && env.EDGE_SECRET && h === 'Bearer ' + env.EDGE_SECRET);
}

export async function onRequestPost(context) {
  const { request, env } = context;
  if (!authed(request, env)) return json({ ok: false, error: 'Not authorized.' }, 401);
  let body = {};
  try { body = await request.json(); } catch (e) {}
  const groups = Array.isArray(body.groups) && body.groups.length ? body.groups : ['board'];
  const bumped = await bumpGens(env, groups);
  // An SMS punch just changed the Sheet; the D1 mirror will not have it for a
  // minute or two, so the next reads of these groups come from Apps Script.
  await holdD1(env, groups);
  return json({ ok: true, bumped });
}

export async function onRequestGet(context) {
  const { request, env } = context;
  if (!authed(request, env)) return json({ ok: false, error: 'Not authorized.' }, 401);
  const gens = {};
  for (const g of GROUPS) gens[g] = await getGen(env, g);
  return json({ ok: true, gens });
}

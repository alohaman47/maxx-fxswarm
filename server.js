'use strict';
// MAXX FX SWARM - server (brain + referee)
// EA posts closed M15 bars for all pairs -> server asks a cheap/free AI in batches ->
// commands go back to the EA. Every signal is also tracked in virtual books
// (AI, REVERSE, calibration by confidence) so we can prove whether the AI has an edge.

const express = require('express');
const fs = require('fs');
const path = require('path');

const VERSION = 'v1.0.3';
const env = (k, d) => (process.env[k] !== undefined && process.env[k] !== '' ? process.env[k] : d);
const num = (k, d) => { const v = parseFloat(env(k, '')); return isFinite(v) ? v : d; };
const list = (k) => String(env(k, '')).split(',').map(s => s.trim()).filter(Boolean);

const CFG = {
  port: num('PORT', 3000),
  key: env('MAXX_KEY', ''),
  dataDir: env('DATA_DIR', env('RAILWAY_VOLUME_MOUNT_PATH', path.join(__dirname, 'data'))),
  provider: env('AI_PROVIDER', 'auto'), // auto | gemini | openai | anthropic | mock
  geminiKeys: list('GEMINI_KEYS').concat(list('GEMINI_API_KEY')),
  geminiModel: env('GEMINI_MODEL', 'auto'), // auto = pick newest free Flash-Lite from Google's model list
  openaiKeys: list('OPENAI_KEYS'),
  openaiBase: env('OPENAI_BASE_URL', 'https://api.groq.com/openai/v1'),
  openaiModel: env('OPENAI_MODEL', 'llama-3.3-70b-versatile'),
  openaiJson: env('OPENAI_JSON_MODE', '1') === '1',
  anthropicKey: env('ANTHROPIC_API_KEY', ''),
  anthropicModel: env('ANTHROPIC_MODEL', 'claude-haiku-5-5'),
  minConf: num('MIN_CONF', 80),
  batchSize: Math.max(1, Math.round(num('BATCH_SIZE', 5))),
  aiGapMs: num('AI_GAP_MS', 5000),
  aiDailyLimit: num('AI_DAILY_LIMIT', 900),
  aiStartNY: num('AI_START_NY', 3),
  aiEndNY: num('AI_END_NY', 12),
  aiBars: Math.round(num('AI_BARS', 20)),
  signalMaxAgeMin: num('SIGNAL_MAX_AGE_MIN', 10),
  slAtr: num('SL_ATR', 1.0),
  beAtr: num('BE_ATR', 1.0),
  trailStartAtr: num('TRAIL_START_ATR', 1.5),
  trailDistAtr: num('TRAIL_DIST_ATR', 1.0),
  tpAtr: num('TP_ATR', 3.0),
  maxHoldBars: Math.round(num('MAX_HOLD_BARS', 32)),
  cmdTtlSec: num('CMD_TTL_SEC', 180),
  newsOn: env('NEWS_GUARD', '1') === '1',
  newsBefore: num('NEWS_BEFORE_MIN', 15),
  newsAfter: num('NEWS_AFTER_MIN', 15),
  newsUrl: env('NEWS_URL', 'https://nfs.faireconomy.media/ff_calendar_thisweek.json'),
};

function pickProvider() {
  if (CFG.provider !== 'auto') return CFG.provider;
  if (CFG.geminiKeys.length) return 'gemini';
  if (CFG.openaiKeys.length) return 'openai';
  if (CFG.anthropicKey) return 'anthropic';
  return 'mock';
}
const PROVIDER = pickProvider();
let MODEL = PROVIDER === 'gemini' ? CFG.geminiModel : PROVIDER === 'openai' ? CFG.openaiModel
  : PROVIDER === 'anthropic' ? CFG.anthropicModel : 'mock-rule';

fs.mkdirSync(CFG.dataDir, { recursive: true });
const F = (n) => path.join(CFG.dataDir, n);
const appendJsonl = (n, o) => { try { fs.appendFileSync(F(n), JSON.stringify(o) + '\n'); } catch (e) { console.error('[DISK]', e.message); } };

// ---------------- time helpers (NY) ----------------
function nyParts(d = new Date()) {
  const p = {};
  for (const x of new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short' }).formatToParts(d)) p[x.type] = x.value;
  const hour = parseInt(p.hour, 10) % 24;
  return { day: `${p.year}-${p.month}-${p.day}`, hour, min: parseInt(p.minute, 10), wd: p.weekday };
}
function aiWindowOpen() {
  const n = nyParts();
  if (n.wd === 'Sat' || n.wd === 'Sun') return false;
  const h = n.hour + n.min / 60;
  return h >= CFG.aiStartNY && h < CFG.aiEndNY;
}

// ---------------- state ----------------
const newStats = () => ({ n: 0, w: 0, sumR: 0, gp: 0, gl: 0 });
const BUCKETS = ['<60', '60-69', '70-79', '80-89', '90+'];
const bucketOf = (c) => c < 60 ? '<60' : c < 70 ? '60-69' : c < 80 ? '70-79' : c < 90 ? '80-89' : '90+';

let S = {
  paused: false,
  pairs: {},                       // sym -> {d, atr, spr, bars:[{t,o,h,l,c}], lastT}
  books: { AI: {}, REV: {} },      // sym -> open virtual trade
  calibOpen: [],
  stats: { AI: newStats(), REV: newStats(), calib: Object.fromEntries(BUCKETS.map(b => [b, newStats()])),
    side: { BUY: newStats(), SELL: newStats() } },
  closed: [],
  decisions: [],
  cmds: [], cmdSeq: 0,
  ea: { lastAt: 0, dayPL: 0, equity: 0, positions: [], dry: true, locked: false, ver: '', acks: [] },
  ai: { day: '', calls: 0, errors: 0, lastErr: '', lastOkAt: 0, keyIdx: 0, signals: 0 },
  feed: [],
  news: { events: [], fetchedAt: 0, err: '' },
  tradeSeq: 0,
};
function feed(msg) {
  const line = `${new Date().toISOString().slice(11, 19)}Z ${msg}`;
  S.feed.unshift(line); S.feed.length = Math.min(S.feed.length, 150);
  console.log('[FEED]', msg);
}
function save() {
  try {
    const keep = { ...S, feed: S.feed.slice(0, 60), decisions: S.decisions.slice(0, 150), closed: S.closed.slice(0, 200) };
    fs.writeFileSync(F('state.tmp'), JSON.stringify(keep));
    fs.renameSync(F('state.tmp'), F('state.json'));
  } catch (e) { console.error('[SAVE]', e.message); }
}
try {
  const raw = JSON.parse(fs.readFileSync(F('state.json'), 'utf8'));
  S = { ...S, ...raw, stats: { ...S.stats, ...(raw.stats || {}) } };
  for (const b of BUCKETS) if (!S.stats.calib[b]) S.stats.calib[b] = newStats();
  console.log('[BOOT] state restored');
} catch { console.log('[BOOT] fresh state'); }

// ---------------- indicators ----------------
function ema(arr, n) { const k = 2 / (n + 1); let e = arr[0]; const out = [e]; for (let i = 1; i < arr.length; i++) { e = arr[i] * k + e * (1 - k); out.push(e); } return out; }
function rsi(c, n = 14) {
  if (c.length <= n) return 50; let g = 0, l = 0;
  for (let i = 1; i <= n; i++) { const d = c[i] - c[i - 1]; if (d > 0) g += d; else l -= d; }
  g /= n; l /= n;
  for (let i = n + 1; i < c.length; i++) { const d = c[i] - c[i - 1]; g = (g * (n - 1) + Math.max(d, 0)) / n; l = (l * (n - 1) + Math.max(-d, 0)) / n; }
  return l === 0 ? 100 : 100 - 100 / (1 + g / l);
}
function features(p) {
  const b = p.bars; const c = b.map(x => x.c); const n = c.length; const atr = p.atr || 1e-9;
  const e20 = ema(c, 20), e50 = ema(c, 50);
  const last20 = b.slice(-20); const hi = Math.max(...last20.map(x => x.h)); const lo = Math.min(...last20.map(x => x.l));
  const h1 = []; for (let i = n - 24; i < n; i += 4) if (i + 3 < n && i >= 0) h1.push(c[i + 3]);
  return {
    trend: e20[n - 1] > e50[n - 1] ? 'EMA20>EMA50' : 'EMA20<EMA50',
    slope: ((e20[n - 1] - e20[Math.max(0, n - 6)]) / atr).toFixed(2),
    rsi: rsi(c).toFixed(1),
    pos: hi > lo ? ((c[n - 1] - lo) / (hi - lo)).toFixed(2) : '0.50',
    h1: h1.map(v => v.toFixed(p.d)).join(' '),
    sprAtr: (p.spr / atr).toFixed(2),
  };
}

// ---------------- news guard ----------------
async function fetchNews() {
  if (!CFG.newsOn) return;
  try {
    const r = await fetch(CFG.newsUrl, { headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36' } });
    if (!r.ok) throw new Error('http ' + r.status);
    const arr = await r.json();
    S.news.events = arr.filter(e => String(e.impact).toLowerCase() === 'high')
      .map(e => ({ ccy: e.country, title: e.title, at: Date.parse(e.date) })).filter(e => isFinite(e.at));
    S.news.fetchedAt = Date.now(); S.news.err = '';
    fs.writeFileSync(F('news.json'), JSON.stringify(S.news));
    feed(`[NEWS] fetched ${S.news.events.length} high-impact events`);
  } catch (e) {
    S.news.err = e.message; feed(`[NEWS] fetch failed ${e.message}`);
    setTimeout(fetchNews, 2 * 3600e3);
  }
}
function newsFor(sym, now = Date.now()) {
  if (!CFG.newsOn) return null;
  const a = sym.slice(0, 3), q = sym.slice(3, 6);
  return S.news.events.find(e => (e.ccy === a || e.ccy === q) &&
    now >= e.at - CFG.newsBefore * 60e3 && now <= e.at + CFG.newsAfter * 60e3) || null;
}
function nextNewsFor(sym, now = Date.now()) {
  const a = sym.slice(0, 3), q = sym.slice(3, 6);
  return S.news.events.filter(e => (e.ccy === a || e.ccy === q) && e.at > now && e.at - now < 3 * 3600e3)
    .sort((x, y) => x.at - y.at)[0] || null;
}

// ---------------- virtual trades ----------------
function openVirtual(book, sym, dir, conf, why, p) {
  const atr = p.atr; const last = p.bars[p.bars.length - 1];
  const tr = { id: ++S.tradeSeq, book, sym, dir, conf, why, entry: last.c, atr,
    sl: last.c - dir * CFG.slAtr * atr, sl0: last.c - dir * CFG.slAtr * atr, tp: last.c + dir * CFG.tpAtr * atr,
    maxFav: 0, bars: 0, openT: last.t, openAt: Date.now(), sprR: p.spr / (CFG.slAtr * atr) };
  return tr;
}
function closeVirtual(tr, price, reason) {
  const R = ((price - tr.entry) * tr.dir) / (CFG.slAtr * tr.atr) - tr.sprR;
  const rec = { id: tr.id, book: tr.book, sym: tr.sym, dir: tr.dir > 0 ? 'BUY' : 'SELL', conf: tr.conf,
    R: +R.toFixed(3), reason, bars: tr.bars, openAt: tr.openAt, closedAt: Date.now() };
  const add = (st) => { st.n++; st.sumR += R; if (R > 0) { st.w++; st.gp += R; } else st.gl -= R; };
  if (tr.book === 'CAL') { add(S.stats.calib[bucketOf(tr.conf)]); add(S.stats.side[rec.dir]); }
  else add(S.stats[tr.book]);
  if (tr.book !== 'CAL') { S.closed.unshift(rec); S.closed.length = Math.min(S.closed.length, 300); }
  appendJsonl('trades.jsonl', rec);
  return rec;
}
// returns closed record or null
function stepVirtual(tr, b) {
  if (b.t <= tr.openT) return null;
  tr.bars++;
  const d = tr.dir;
  const hitSL = d > 0 ? b.l <= tr.sl : b.h >= tr.sl;
  if (hitSL) {
    const tiny = tr.atr * 0.01;
    const reason = Math.abs(tr.sl - tr.sl0) < tiny ? 'SL' : Math.abs(tr.sl - tr.entry) < tiny ? 'BE' : 'TRAIL';
    return closeVirtual(tr, tr.sl, reason);
  }
  const hitTP = d > 0 ? b.h >= tr.tp : b.l <= tr.tp;
  if (hitTP) return closeVirtual(tr, tr.tp, 'TP');
  tr.maxFav = Math.max(tr.maxFav, d > 0 ? b.h - tr.entry : tr.entry - b.l);
  if (tr.maxFav >= CFG.beAtr * tr.atr) tr.sl = d > 0 ? Math.max(tr.sl, tr.entry) : Math.min(tr.sl, tr.entry);
  if (tr.maxFav >= CFG.trailStartAtr * tr.atr) {
    const ts = tr.entry + d * (tr.maxFav - CFG.trailDistAtr * tr.atr);
    tr.sl = d > 0 ? Math.max(tr.sl, ts) : Math.min(tr.sl, ts);
  }
  if (tr.bars >= CFG.maxHoldBars) return closeVirtual(tr, b.c, 'TIME');
  return null;
}
function stepAllVirtual(sym, newBars) {
  for (const b of newBars) {
    for (const book of ['AI', 'REV']) {
      const tr = S.books[book][sym];
      if (tr && stepVirtual(tr, b)) delete S.books[book][sym];
    }
    S.calibOpen = S.calibOpen.filter(tr => tr.sym !== sym || !stepVirtual(tr, b));
  }
}

// ---------------- AI ----------------
const SYS = `You are a disciplined FX intraday analyst working on M15 charts.
For each pair you get indicators and the last closed M15 bars. Decide BUY, SELL or NONE for a trade that will be managed mechanically:
stop-loss 1 ATR, break-even at +1 ATR, trailing stop from +1.5 ATR, take-profit +3 ATR, max hold 8 hours.
Only call BUY or SELL when you expect price to travel at least 1.5 ATR in your direction before it moves 1 ATR against you.
Most of the time the correct answer is NONE. Do not force trades. Avoid pairs with a high-impact news event soon.
"conf" = your honest probability (0-100) that the trade reaches +1.5 ATR before -1 ATR. 50 means coin flip.
Reply with JSON only, no markdown:
{"signals":[{"pair":"EURUSD","action":"BUY|SELL|NONE","conf":0-100,"why":"short reason in Thai, max 15 words"}]}
Return exactly one entry per pair given.`;

function buildPrompt(syms) {
  const ny = nyParts();
  let out = `Time now New York ${ny.day} ${String(ny.hour).padStart(2, '0')}:${String(ny.min).padStart(2, '0')}\n`;
  for (const s of syms) {
    const p = S.pairs[s]; const f = features(p); const nn = nextNewsFor(s);
    out += `\n=== ${s} ===\nATR14 ${p.atr.toFixed(p.d)} | spread ${f.sprAtr} ATR | ${f.trend} | EMA20 slope ${f.slope} ATR per 5 bars | RSI14 ${f.rsi} | position in 20-bar range ${f.pos}\n`;
    out += `Last 6 H1 closes: ${f.h1}\n`;
    if (nn) out += `NEWS: ${nn.ccy} ${nn.title} in ${Math.round((nn.at - Date.now()) / 60e3)} min\n`;
    out += `M15 bars oldest->newest (o,h,l,c):\n`;
    for (const b of p.bars.slice(-CFG.aiBars)) out += [b.o, b.h, b.l, b.c].map(v => v.toFixed(p.d)).join(',') + '\n';
  }
  return out;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
function extractJson(text) {
  const a = text.indexOf('{'), b = text.lastIndexOf('}');
  if (a < 0 || b <= a) throw new Error('no JSON in reply');
  return JSON.parse(text.slice(a, b + 1));
}

// Gemini model auto-pick: Google retires model names often, so ask the API which models exist
let geminiModel = CFG.geminiModel === 'auto' ? '' : CFG.geminiModel;
let geminiCands = []; const geminiBad = {}; // model -> blocked-until ms
async function resolveGeminiModel(force) {
  if (PROVIDER !== 'gemini') return;
  if (geminiModel && !force) return;
  const key = CFG.geminiKeys[0];
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models?pageSize=200&key=${encodeURIComponent(key)}`);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`gemini list models http ${r.status} ${(j.error && j.error.message || '').slice(0, 200)}`);
  const names = (j.models || []).filter(m => (m.supportedGenerationMethods || []).includes('generateContent'))
    .map(m => String(m.name).replace(/^models\//, ''))
    .filter(n => /^gemini-[\d.]+-flash/.test(n) && !/(image|tts|audio|live|thinking|exp|native|embedding|computer)/.test(n));
  const ver = (n) => parseFloat((n.match(/^gemini-([\d.]+)/) || [0, 0])[1]) || 0;
  const score = (n) => (/flash-lite/.test(n) ? 10000 : 0) + ver(n) * 100 + (/preview/.test(n) ? 0 : 5) - (/-\d{3,}$/.test(n) ? 1 : 0);
  names.sort((a, b) => score(b) - score(a));
  if (!names.length) throw new Error('no Gemini flash model available for this key');
  geminiCands = names;
  const usable = names.filter(n => !(geminiBad[n] > Date.now()));
  if (!usable.length) throw new Error('all Gemini models out of free quota - wait for daily reset (midnight Pacific) or add another key');
  const old = geminiModel; geminiModel = usable[0]; MODEL = geminiModel;
  feed(`[AI] Gemini model -> ${geminiModel}${old ? ' (was ' + old + ')' : ''} | candidates: ${names.slice(0, 5).join(', ')}`);
}
async function callOnce(prompt, key) {
  if (PROVIDER === 'gemini') {
    if (!geminiModel) await resolveGeminiModel();
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${geminiModel}:generateContent?key=${encodeURIComponent(key)}`;
    const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({
      systemInstruction: { parts: [{ text: SYS }] },
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      generationConfig: { temperature: 0.2, maxOutputTokens: 2048, responseMimeType: 'application/json' } }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(`gemini http ${r.status} ${(j.error && j.error.message || '').slice(0, 300)}`); e.status = r.status; throw e; }
    const parts = (((j.candidates || [])[0] || {}).content || {}).parts || [];
    return parts.map(p => p.text || '').join('');
  }
  if (PROVIDER === 'openai') {
    const body = { model: CFG.openaiModel, temperature: 0.2, max_tokens: 2048,
      messages: [{ role: 'system', content: SYS }, { role: 'user', content: prompt }] };
    if (CFG.openaiJson) body.response_format = { type: 'json_object' };
    const r = await fetch(`${CFG.openaiBase}/chat/completions`, { method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(`openai http ${r.status} ${JSON.stringify(j.error || '').slice(0, 120)}`); e.status = r.status; throw e; }
    return (((j.choices || [])[0] || {}).message || {}).content || '';
  }
  if (PROVIDER === 'anthropic') {
    const r = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: CFG.anthropicModel, max_tokens: 2048, system: SYS, messages: [{ role: 'user', content: prompt }] }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(`anthropic http ${r.status} ${JSON.stringify(j.error || '').slice(0, 120)}`); e.status = r.status; throw e; }
    return (j.content || []).filter(c => c.type === 'text').map(c => c.text).join('');
  }
  throw new Error('no provider');
}
function mockAnswer(syms) {
  return JSON.stringify({ signals: syms.map(s => {
    const f = features(S.pairs[s]); const sl = parseFloat(f.slope); const r = parseFloat(f.rsi);
    let action = 'NONE', conf = 50;
    if (sl > 0.3 && r > 55 && r < 72) { action = 'BUY'; conf = Math.min(95, Math.round(60 + sl * 30)); }
    else if (sl < -0.3 && r < 45 && r > 28) { action = 'SELL'; conf = Math.min(95, Math.round(60 - sl * 30)); }
    return { pair: s, action, conf, why: 'mock: slope ' + f.slope + ' rsi ' + f.rsi };
  }) });
}
async function askAI(syms) {
  const today = nyParts().day;
  if (S.ai.day !== today) { S.ai.day = today; S.ai.calls = 0; S.ai.errors = 0; }
  if (S.ai.calls >= CFG.aiDailyLimit) throw new Error('daily AI limit reached');
  const prompt = buildPrompt(syms);
  if (PROVIDER === 'mock') { S.ai.calls++; return extractJson(mockAnswer(syms)); }
  const keys = PROVIDER === 'gemini' ? CFG.geminiKeys : PROVIDER === 'openai' ? CFG.openaiKeys : [CFG.anthropicKey];
  let lastErr;
  for (let attempt = 0; attempt < keys.length + 4; attempt++) {
    const key = keys[S.ai.keyIdx % keys.length];
    try {
      S.ai.calls++;
      const text = await callOnce(prompt, key);
      if (!text.trim()) throw Object.assign(new Error('empty reply'), { status: 599 });
      S.ai.keyIdx++; // round-robin across keys
      return extractJson(text);
    } catch (e) {
      lastErr = e;
      console.error('[AI ERROR]', e.message);
      if (PROVIDER === 'gemini' && e.status === 429 && /quota/i.test(e.message) && keys.length === 1) {
        // free quota for this model is gone (or zero) -> park it 6h and try the next model
        geminiBad[geminiModel] = Date.now() + 6 * 3600e3;
        try { await resolveGeminiModel(true); continue; } catch (e2) { lastErr = e2; console.error('[AI ERROR]', e2.message); break; }
      }
      if (e.status === 429 || (e.status >= 500)) { S.ai.keyIdx++; await sleep(2500); continue; }
      if (PROVIDER === 'gemini' && e.status === 404 && attempt === 0) {
        try { await resolveGeminiModel(true); continue; } catch (e2) { lastErr = e2; console.error('[AI ERROR]', e2.message); }
      }
      break;
    }
  }
  throw lastErr;
}

// queue: one batch at a time, spaced by AI_GAP_MS; newer bar generation drops stale batches
let gen = 0; let queue = []; let busy = false;
function enqueue(syms) {
  gen++;
  queue = [];
  for (let i = 0; i < syms.length; i += CFG.batchSize) queue.push({ gen, syms: syms.slice(i, i + CFG.batchSize), at: Date.now() });
  pump();
}
async function pump() {
  if (busy) return; busy = true;
  try {
    while (queue.length) {
      const job = queue.shift();
      if (job.gen !== gen) continue;
      if (Date.now() - job.at > CFG.signalMaxAgeMin * 60e3) { feed(`[AI] batch ${job.syms.join(',')} too old, dropped`); continue; }
      try {
        const res = await askAI(job.syms);
        S.ai.lastOkAt = Date.now();
        handleSignals(job.syms, res);
      } catch (e) {
        S.ai.errors++; S.ai.lastErr = e.message.slice(0, 160);
        feed(`[AI ERROR] ${job.syms.join(',')} -> skip this cycle (${S.ai.lastErr})`);
      }
      save();
      if (queue.length) await sleep(CFG.aiGapMs);
    }
  } finally { busy = false; }
}

function pushCmd(action, sym, dir, conf) {
  const c = { id: ++S.cmdSeq, at: Date.now(), action, sym, dir, conf };
  S.cmds.push(c); S.cmds = S.cmds.filter(x => Date.now() - x.at < 3600e3);
  return c;
}
function handleSignals(syms, res) {
  const arr = Array.isArray(res.signals) ? res.signals : [];
  for (const s of syms) {
    const sig = arr.find(x => String(x.pair || '').toUpperCase().replace(/[^A-Z]/g, '') === s);
    const p = S.pairs[s];
    if (!sig || !p) continue;
    const action = String(sig.action || 'NONE').toUpperCase();
    const conf = Math.max(0, Math.min(100, Math.round(Number(sig.conf) || 0)));
    const why = String(sig.why || '').slice(0, 120);
    const dec = { at: Date.now(), sym: s, action, conf, why, price: p.bars[p.bars.length - 1].c, taken: false, note: '' };
    S.ai.signals++;
    if (action === 'BUY' || action === 'SELL') {
      const dir = action === 'BUY' ? 1 : -1;
      S.calibOpen.push(openVirtual('CAL', s, dir, conf, why, p));
      const nw = newsFor(s);
      if (conf < CFG.minConf) dec.note = `conf < ${CFG.minConf}`;
      else if (nw) dec.note = `news ${nw.ccy} ${nw.title}`;
      else if (S.paused) dec.note = 'paused';
      else {
        for (const [book, d] of [['AI', dir], ['REV', -dir]]) {
          const cur = S.books[book][s];
          if (cur && cur.dir === d) continue;
          if (cur) { closeVirtual(cur, p.bars[p.bars.length - 1].c, 'FLIP'); delete S.books[book][s]; }
          S.books[book][s] = openVirtual(book, s, d, conf, why, p);
        }
        const c = pushCmd('OPEN', s, action, conf);
        dec.taken = true; dec.note = `cmd #${c.id}`;
        feed(`[SIGNAL] ${s} ${action} conf ${conf} -> cmd #${c.id} | ${why}`);
      }
    }
    S.decisions.unshift(dec); S.decisions.length = Math.min(S.decisions.length, 300);
    appendJsonl('decisions.jsonl', dec);
  }
}

// ---------------- HTTP ----------------
const app = express();
app.use(express.json({ limit: '2mb' }));
app.use(express.text({ limit: '200kb' }));
const auth = (req, res, next) => {
  const k = req.get('x-maxx-key') || req.query.key || '';
  if (!CFG.key || k !== CFG.key) return res.status(401).json({ ok: false, err: 'bad key' });
  next();
};

app.get('/health', (req, res) => res.json({ ok: true, version: VERSION, aiMode: PROVIDER === 'mock' ? 'mock' : 'live',
  provider: PROVIDER, model: MODEL, keys: PROVIDER === 'gemini' ? CFG.geminiKeys.length : PROVIDER === 'openai' ? CFG.openaiKeys.length : PROVIDER === 'anthropic' ? 1 : 0,
  keySet: !!CFG.key, dataDir: CFG.dataDir, newsEvents: S.news.events.length, eaAgeSec: S.ea.lastAt ? Math.round((Date.now() - S.ea.lastAt) / 1000) : null }));

// EA -> closed bars for all pairs
app.post('/api/bar', auth, (req, res) => {
  const b = req.body || {};
  S.ea = { ...S.ea, lastAt: Date.now(), dayPL: +b.dayPL || 0, equity: +b.equity || 0, positions: Array.isArray(b.positions) ? b.positions : [],
    dry: !!b.dry, locked: !!b.locked, ver: String(b.ver || '') };
  let fresh = [];
  for (const q of (b.pairs || [])) {
    const sym = String(q.s || '').toUpperCase(); if (!sym || !Array.isArray(q.t)) continue;
    const bars = q.t.map((t, i) => ({ t: +t, o: +q.o[i], h: +q.h[i], l: +q.l[i], c: +q.c[i] })).filter(x => isFinite(x.c));
    if (!bars.length || !(+q.atr > 0)) continue;
    const prev = S.pairs[sym]; const lastT = prev ? prev.lastT : 0;
    const newBars = bars.filter(x => x.t > lastT);
    S.pairs[sym] = { d: +q.d || 5, atr: +q.atr, spr: +q.spr || 0, bars: bars.slice(-120), lastT: bars[bars.length - 1].t };
    if (prev && newBars.length) stepAllVirtual(sym, newBars);
    if (newBars.length && bars.length >= 30) fresh.push(sym);
  }
  let note = 'stored';
  if (!fresh.length) note = 'no new bars';
  else if (S.paused) note = 'paused';
  else if (S.ea.locked) note = 'EA day locked';
  else if (!aiWindowOpen()) note = 'outside AI window';
  else { enqueue(fresh); note = `queued ${fresh.length} pairs in ${Math.ceil(fresh.length / CFG.batchSize)} batches`; }
  feed(`[BAR] ${fresh.length} new | dayPL ${S.ea.dayPL.toFixed(2)} | ${note}`);
  save();
  res.json({ ok: true, note });
});

// EA polls commands: plain text "id;ACTION;SYM;DIR;CONF" per line
app.get('/api/cmd', auth, (req, res) => {
  const since = parseInt(req.query.since || '0', 10) || 0;
  S.ea.lastAt = Date.now();
  const out = S.cmds.filter(c => c.id > since && Date.now() - c.at < CFG.cmdTtlSec * 1000)
    .map(c => `${c.id};${c.action};${c.sym};${c.dir};${c.conf}`).join('\n');
  res.type('text/plain').send(out);
});
app.post('/api/ack', auth, (req, res) => {
  const a = typeof req.body === 'object' ? req.body : {};
  const rec = { at: Date.now(), id: a.id, st: a.st, msg: String(a.msg || '').slice(0, 200) };
  S.ea.acks.unshift(rec); S.ea.acks.length = Math.min(S.ea.acks.length, 80);
  appendJsonl('acks.jsonl', rec);
  feed(`[ACK] #${rec.id} ${rec.st} ${rec.msg}`);
  res.json({ ok: true });
});

app.get('/api/state', auth, (req, res) => {
  const pf = (st) => st.gl > 0 ? +(st.gp / st.gl).toFixed(2) : (st.gp > 0 ? 99 : 0);
  const sum = (st) => ({ n: st.n, win: st.n ? +(100 * st.w / st.n).toFixed(1) : 0, pf: pf(st), sumR: +st.sumR.toFixed(2), avgR: st.n ? +(st.sumR / st.n).toFixed(3) : 0 });
  res.json({
    version: VERSION, provider: PROVIDER, model: MODEL, aiMode: PROVIDER === 'mock' ? 'mock' : 'live', paused: S.paused,
    cfg: { minConf: CFG.minConf, batch: CFG.batchSize, window: `${CFG.aiStartNY}-${CFG.aiEndNY} NY`, aiLimit: CFG.aiDailyLimit,
      exits: `SL ${CFG.slAtr} / BE ${CFG.beAtr} / trail ${CFG.trailStartAtr} (dist ${CFG.trailDistAtr}) / TP ${CFG.tpAtr} ATR / ${CFG.maxHoldBars} bars` },
    windowOpen: aiWindowOpen(), ny: nyParts(),
    ai: S.ai, ea: { ...S.ea, ageSec: S.ea.lastAt ? Math.round((Date.now() - S.ea.lastAt) / 1000) : null },
    books: { AI: sum(S.stats.AI), REV: sum(S.stats.REV) },
    calib: BUCKETS.map(b => ({ bucket: b, ...sum(S.stats.calib[b]) })),
    side: { BUY: sum(S.stats.side.BUY), SELL: sum(S.stats.side.SELL) },
    open: Object.values(S.books.AI).map(t => ({ sym: t.sym, dir: t.dir > 0 ? 'BUY' : 'SELL', conf: t.conf, bars: t.bars,
      R: S.pairs[t.sym] ? +(((S.pairs[t.sym].bars.slice(-1)[0].c - t.entry) * t.dir) / (CFG.slAtr * t.atr)).toFixed(2) : 0 })),
    calibOpen: S.calibOpen.length,
    closed: S.closed.slice(0, 40), decisions: S.decisions.slice(0, 60), feed: S.feed.slice(0, 60),
    news: { n: S.news.events.length, err: S.news.err, fetchedAt: S.news.fetchedAt,
      next: S.news.events.filter(e => e.at > Date.now()).sort((a, b) => a.at - b.at).slice(0, 5) },
    pairs: Object.keys(S.pairs).length,
  });
});
app.post('/api/pause', auth, (req, res) => { S.paused = true; feed('[CTRL] paused'); save(); res.json({ ok: true }); });
app.post('/api/resume', auth, (req, res) => { S.paused = false; feed('[CTRL] resumed'); save(); res.json({ ok: true }); });
app.post('/api/closeall', auth, (req, res) => { const c = pushCmd('CLOSEALL', '*', '-', 0); feed(`[CTRL] close-all cmd #${c.id}`); save(); res.json({ ok: true, id: c.id }); });
app.get('/api/log', auth, (req, res) => {
  const name = { trades: 'trades.jsonl', decisions: 'decisions.jsonl', acks: 'acks.jsonl' }[req.query.f] || 'decisions.jsonl';
  try { res.type('text/plain').send(fs.readFileSync(F(name), 'utf8')); } catch { res.type('text/plain').send(''); }
});
app.use(express.static(path.join(__dirname, 'public')));

if (require.main === module) {
  app.listen(CFG.port, () => {
    console.log(`[BOOT] MAXX FX SWARM ${VERSION} port ${CFG.port} provider ${PROVIDER} model ${MODEL} data ${CFG.dataDir}`);
    if (!CFG.key) console.warn('[WARN] MAXX_KEY not set - every API call will be rejected');
    if (PROVIDER === 'mock') console.warn('[WARN] AI MOCK MODE - no real AI is called (set GEMINI_KEYS)');
  });
  try { S.news = JSON.parse(fs.readFileSync(F('news.json'), 'utf8')); } catch {}
  if (Date.now() - (S.news.fetchedAt || 0) > 6 * 3600e3) fetchNews();
  resolveGeminiModel().catch(e => { S.ai.lastErr = e.message.slice(0, 300); feed(`[AI ERROR] ${S.ai.lastErr}`); });
  setInterval(fetchNews, 12 * 3600e3);
  setInterval(save, 60e3);
}
module.exports = { app, S, CFG };

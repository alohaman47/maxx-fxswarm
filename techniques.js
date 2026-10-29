'use strict';
// MAXX FX SWARM - technique lab: 10 popular FX techniques as pure functions.
// Shared by server.js (live forward books) and backtest.js (history replay),
// so both use the exact same rules. Every function looks only at closed bars
// up to the last element of the arrays (no look-ahead).
//
// bars: [{t,o,h,l,c}] oldest -> newest, t = MT5 server time (epoch seconds, server clock)
// ctx:  { offsetH } server time minus New York time in hours (Pepperstone = 7)

const BOOK_INFO = {
  EMA:  { name: 'EMA Cross 9/21',        fam: 'trend' },
  MACD: { name: 'MACD + EMA200',         fam: 'trend' },
  ST:   { name: 'Supertrend 10/3',       fam: 'trend' },
  ICHI: { name: 'Ichimoku TK Cross',     fam: 'trend' },
  DON:  { name: 'Donchian 20 Breakout',  fam: 'breakout' },
  LONB: { name: 'London Breakout',       fam: 'breakout' },
  BB:   { name: 'Bollinger Fade 20/2',   fam: 'fade' },
  RSI:  { name: 'RSI 30/70 Reversal',    fam: 'fade' },
  STO:  { name: 'Stochastic 14/3/3',     fam: 'fade' },
  PIV:  { name: 'Pivot S1/R1 Bounce',    fam: 'fade' },
};
const CODES = Object.keys(BOOK_INFO);

// ---------- indicator helpers ----------
function ema(a, n) {
  const k = 2 / (n + 1); const out = new Array(a.length);
  // seed with SMA of first n values (more standard than seeding at a[0])
  let s = 0; const m = Math.min(n, a.length);
  for (let i = 0; i < m; i++) { s += a[i]; out[i] = s / (i + 1); }
  let e = out[m - 1];
  for (let i = m; i < a.length; i++) { e = a[i] * k + e * (1 - k); out[i] = e; }
  return out;
}
function sma(a, n) {
  const out = new Array(a.length).fill(NaN); let s = 0;
  for (let i = 0; i < a.length; i++) { s += a[i]; if (i >= n) s -= a[i - n]; if (i >= n - 1) out[i] = s / n; }
  return out;
}
function rsiSeries(c, n = 14) {
  const out = new Array(c.length).fill(NaN);
  if (c.length <= n) return out;
  let g = 0, l = 0;
  for (let i = 1; i <= n; i++) { const d = c[i] - c[i - 1]; if (d > 0) g += d; else l -= d; }
  g /= n; l /= n; out[n] = l === 0 ? 100 : 100 - 100 / (1 + g / l);
  for (let i = n + 1; i < c.length; i++) {
    const d = c[i] - c[i - 1];
    g = (g * (n - 1) + Math.max(d, 0)) / n; l = (l * (n - 1) + Math.max(-d, 0)) / n;
    out[i] = l === 0 ? 100 : 100 - 100 / (1 + g / l);
  }
  return out;
}
function atrSeries(h, l, c, n) {
  const out = new Array(c.length).fill(NaN); let a = 0;
  for (let i = 1; i < c.length; i++) {
    const tr = Math.max(h[i] - l[i], Math.abs(h[i] - c[i - 1]), Math.abs(l[i] - c[i - 1]));
    if (i <= n) { a += tr; if (i === n) { a /= n; out[i] = a; } }
    else { a = (a * (n - 1) + tr) / n; out[i] = a; }
  }
  return out;
}
const hh = (h, from, to) => { let m = -Infinity; for (let i = Math.max(0, from); i <= to; i++) if (h[i] > m) m = h[i]; return m; };
const ll = (l, from, to) => { let m = Infinity; for (let i = Math.max(0, from); i <= to; i++) if (l[i] < m) m = l[i]; return m; };
const sgn = (x) => (x > 0 ? 1 : x < 0 ? -1 : 0);
function crossDir(a, b, i) { // +1 a crosses above b at bar i, -1 below, 0 none
  const now = a[i] - b[i], prev = a[i - 1] - b[i - 1];
  if (!isFinite(now) || !isFinite(prev)) return 0;
  if (prev <= 0 && now > 0) return 1;
  if (prev >= 0 && now < 0) return -1;
  return 0;
}

// ---------- techniques (return +1 long, -1 short, 0 none) at last bar ----------
function tEMA(x) { const i = x.n - 1; return crossDir(ema(x.c, 9), ema(x.c, 21), i); }

function tMACD(x) {
  const i = x.n - 1; if (x.n < 210) return 0;
  const e12 = ema(x.c, 12), e26 = ema(x.c, 26);
  const macd = e12.map((v, k) => v - e26[k]); const sig = ema(macd, 9);
  const d = crossDir(macd, sig, i); if (!d) return 0;
  const e200 = ema(x.c, 200)[i];
  return (d > 0 && x.c[i] > e200) || (d < 0 && x.c[i] < e200) ? d : 0;
}

function tST(x, n = 10, mult = 3) {
  const { h, l, c } = x; const len = x.n; if (len < n + 3) return 0;
  const atr = atrSeries(h, l, c, n);
  let fu = NaN, fl = NaN, dir = 1, prevDir = 1;
  for (let i = n; i < len; i++) {
    const mid = (h[i] + l[i]) / 2; const bu = mid + mult * atr[i], bl = mid - mult * atr[i];
    const pfu = fu, pfl = fl;
    fu = isNaN(pfu) || bu < pfu || c[i - 1] > pfu ? bu : pfu;
    fl = isNaN(pfl) || bl > pfl || c[i - 1] < pfl ? bl : pfl;
    prevDir = dir;
    if (!isNaN(pfu)) { if (dir === -1 && c[i] > pfu) dir = 1; else if (dir === 1 && c[i] < pfl) dir = -1; }
  }
  return dir !== prevDir ? dir : 0;
}

function tICHI(x) {
  const { h, l, c } = x; const i = x.n - 1; if (x.n < 52 + 26 + 2) return 0;
  const mid = (a, b) => (a + b) / 2;
  const tenkan = (k) => mid(hh(h, k - 8, k), ll(l, k - 8, k));
  const kijun = (k) => mid(hh(h, k - 25, k), ll(l, k - 25, k));
  const d = sgn(tenkan(i) - kijun(i)), p = sgn(tenkan(i - 1) - kijun(i - 1));
  if (!d || d === p) return 0;
  const k = i - 26; // cloud plotted 26 ahead -> value at i comes from bar i-26
  const spanA = mid(tenkan(k), kijun(k)), spanB = mid(hh(h, k - 51, k), ll(l, k - 51, k));
  const top = Math.max(spanA, spanB), bot = Math.min(spanA, spanB);
  return (d > 0 && c[i] > top) || (d < 0 && c[i] < bot) ? d : 0;
}

function tDON(x, n = 20) {
  const { h, l, c } = x; const i = x.n - 1; if (x.n < n + 3) return 0;
  const up = hh(h, i - n, i - 1), dn = ll(l, i - n, i - 1);
  const upP = hh(h, i - 1 - n, i - 2), dnP = ll(l, i - 1 - n, i - 2);
  if (c[i] > up && c[i - 1] <= upP) return 1;   // fresh close above prior 20-bar high
  if (c[i] < dn && c[i - 1] >= dnP) return -1;
  return 0;
}

// NY clock helpers (bar time t is server clock; NY = server - offsetH)
const nyOf = (t, off) => t - off * 3600;
const nyHour = (t, off) => Math.floor(nyOf(t, off) / 3600) % 24;
const nyDayStart = (t, off) => Math.floor(nyOf(t, off) / 86400) * 86400;          // NY midnight (in NY clock seconds)
const fxDayKey = (t, off) => Math.floor((nyOf(t, off) + 7 * 3600) / 86400);        // FX day rolls at 17:00 NY

function tLONB(x, ctx) {
  const { h, l, c, t } = x; const i = x.n - 1; const off = ctx.offsetH;
  const hr = nyHour(t[i], off); if (hr < 3 || hr >= 6) return 0;   // signal window 03:00-06:00 NY
  const day0 = nyDayStart(t[i], off); const aStart = day0 - 5 * 3600, aEnd = day0 + 3 * 3600; // 19:00 prev -> 03:00
  let hi = -Infinity, lo = Infinity, cnt = 0, firstAfter = -1;
  for (let k = i; k >= 0; k--) {
    const ny = nyOf(t[k], off); if (ny < aStart) break;
    if (ny < aEnd) { cnt++; if (h[k] > hi) hi = h[k]; if (l[k] < lo) lo = l[k]; }
    else firstAfter = k;
  }
  if (cnt < 20 || firstAfter < 0) return 0;                         // need a real Asia range
  for (let k = firstAfter; k < i; k++) if (c[k] > hi || c[k] < lo) return 0;   // first break only
  return c[i] > hi ? 1 : c[i] < lo ? -1 : 0;
}

function tBB(x, n = 20, k = 2) {
  const c = x.c; const i = x.n - 1; if (x.n < n + 2) return 0;
  const band = (j) => { let s = 0, q = 0; for (let m = j - n + 1; m <= j; m++) { s += c[m]; q += c[m] * c[m]; }
    const mu = s / n; const sd = Math.sqrt(Math.max(q / n - mu * mu, 0)); return [mu - k * sd, mu + k * sd]; };
  const [lo1, up1] = band(i - 1), [lo0, up0] = band(i);
  if (c[i - 1] < lo1 && c[i] > lo0) return 1;      // closed outside lower band, now back inside
  if (c[i - 1] > up1 && c[i] < up0) return -1;
  return 0;
}

function tRSI(x) {
  const r = rsiSeries(x.c, 14); const i = x.n - 1;
  if (r[i - 1] < 30 && r[i] >= 30) return 1;
  if (r[i - 1] > 70 && r[i] <= 70) return -1;
  return 0;
}

function tSTO(x, n = 14) {
  const { h, l, c } = x; const len = x.n; if (len < n + 8) return 0;
  const raw = new Array(len).fill(NaN);
  for (let j = n - 1; j < len; j++) { const H = hh(h, j - n + 1, j), L = ll(l, j - n + 1, j); raw[j] = H > L ? 100 * (c[j] - L) / (H - L) : 50; }
  const K = sma(raw.map(v => (isNaN(v) ? 50 : v)), 3), D = sma(K.map(v => (isNaN(v) ? 50 : v)), 3);
  const i = len - 1; const d = crossDir(K, D, i);
  if (d > 0 && Math.min(K[i - 1], D[i - 1]) < 20) return 1;
  if (d < 0 && Math.max(K[i - 1], D[i - 1]) > 80) return -1;
  return 0;
}

function tPIV(x, ctx) {
  const { h, l, c, t } = x; const i = x.n - 1; const off = ctx.offsetH;
  const today = fxDayKey(t[i], off);
  let prevKey = null, H = -Infinity, L = Infinity, C = NaN;
  for (let k = i; k >= 0; k--) {
    const key = fxDayKey(t[k], off); if (key === today) continue;
    if (prevKey === null) { prevKey = key; C = c[k]; }
    if (key !== prevKey) break;
    if (h[k] > H) H = h[k]; if (l[k] < L) L = l[k];
  }
  if (prevKey === null || !isFinite(H)) return 0;
  const P = (H + L + C) / 3, S1 = 2 * P - H, R1 = 2 * P - L;
  if (l[i] <= S1 && c[i] > S1 && c[i - 1] > S1) return 1;     // wick tags S1, closes back above
  if (h[i] >= R1 && c[i] < R1 && c[i - 1] < R1) return -1;
  return 0;
}

// wrappers so the (x, ctx) call never leaks ctx into a numeric default parameter
const FN = {
  EMA: (x) => tEMA(x), MACD: (x) => tMACD(x), ST: (x) => tST(x, 10, 3), ICHI: (x) => tICHI(x),
  DON: (x) => tDON(x, 20), LONB: (x, ctx) => tLONB(x, ctx), BB: (x) => tBB(x, 20, 2),
  RSI: (x) => tRSI(x), STO: (x) => tSTO(x, 14), PIV: (x, ctx) => tPIV(x, ctx),
};

// Evaluate all techniques on the last closed bar of `bars`.
function evalAll(bars, ctx) {
  const x = { n: bars.length, t: bars.map(b => b.t), o: bars.map(b => b.o), h: bars.map(b => b.h), l: bars.map(b => b.l), c: bars.map(b => b.c) };
  const out = [];
  if (x.n < 60) return out;
  for (const code of CODES) {
    let d = 0;
    try { d = FN[code](x, ctx) || 0; } catch (e) { d = 0; }
    if (d) out.push({ code, dir: d });
  }
  return out;
}

module.exports = { BOOK_INFO, CODES, evalAll, nyHour, _fn: FN };

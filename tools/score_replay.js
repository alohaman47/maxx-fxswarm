'use strict';
// Score the AI's answers on the anonymized historical exam.
// usage: node tools/score_replay.js <csv folder> <replay_results.jsonl> [--comm 0.7] [--min 60]
// Same exit engine and costs as backtest.js. Books: AI, REVERSE, RANDOM (same moments), plus calibration.

const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
const [dir, resFile] = args;
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const COMM = parseFloat(opt('--comm', '0.7'));
const MIN = parseFloat(opt('--min', '60'));
const X = { sl: 1, be: 1, trailStart: 1.5, trailDist: 1, tp: 3, maxBars: 32 };
const set = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'replay', 'replay_set.json'), 'utf8'));
const OFF = set.offset || 7;

const P = {};
for (const f of fs.readdirSync(dir).filter(f => /^[A-Z]{6}\.csv$/.test(f))) {
  let sym = f.slice(0, 6), point = 0.00001; const bars = []; const idx = new Map();
  for (const ln of fs.readFileSync(path.join(dir, f), 'utf8').split(/\r?\n/)) {
    if (ln.startsWith('#meta')) { const m = ln.split(','); sym = m[1]; point = +m[3]; continue; }
    const v = ln.split(','); if (!/^\d/.test(v[0])) continue;
    idx.set(+v[0], bars.length); bars.push({ t: +v[0], o: +v[1], h: +v[2], l: +v[3], c: +v[4], spr: (+v[5] || 0) * point });
  }
  P[sym] = { bars, idx };
}
function atrAt(b, i, n = 14) { let s = 0; for (let k = i - n + 1; k <= i; k++) s += Math.max(b[k].h - b[k].l, Math.abs(b[k].h - b[k - 1].c), Math.abs(b[k].l - b[k - 1].c)); return s / n; }
function sim(sym, t, dir) { // returns {net, gross}
  const b = P[sym].bars, i = P[sym].idx.get(t), atr = atrAt(b, i), e = b[i].c;
  const pip = sym.includes('JPY') ? 0.01 : 0.0001; const costR = (b[i].spr + COMM * pip) / (X.sl * atr);
  let sl = e - dir * X.sl * atr, tp = e + dir * X.tp * atr, mf = 0, px = null;
  for (let k = i + 1, n = 1; k < b.length; k++, n++) {
    const x = b[k];
    if (dir > 0 ? x.l <= sl : x.h >= sl) { px = sl; break; }
    if (dir > 0 ? x.h >= tp : x.l <= tp) { px = tp; break; }
    mf = Math.max(mf, dir > 0 ? x.h - e : e - x.l);
    if (mf >= X.be * atr) sl = dir > 0 ? Math.max(sl, e) : Math.min(sl, e);
    if (mf >= X.trailStart * atr) { const ts = e + dir * (mf - X.trailDist * atr); sl = dir > 0 ? Math.max(sl, ts) : Math.min(sl, ts); }
    if (n >= X.maxBars) { px = x.c; break; }
  }
  if (px === null) return null;
  const gross = ((px - e) * dir) / (X.sl * atr);
  return { gross, net: gross - costR };
}
function stat(a) {
  const n = a.length; if (!n) return { n: 0, avgR: 0, t: 0, pf: 0, win: 0, sumR: 0 };
  const s = a.reduce((x, y) => x + y, 0), m = s / n, sd = Math.sqrt(a.reduce((x, y) => x + (y - m) ** 2, 0) / Math.max(n - 1, 1));
  const gp = a.filter(x => x > 0).reduce((x, y) => x + y, 0), gl = -a.filter(x => x <= 0).reduce((x, y) => x + y, 0);
  return { n, sumR: +s.toFixed(1), avgR: +m.toFixed(3), t: +(m / (sd / Math.sqrt(n) || 1)).toFixed(2), pf: gl ? +(gp / gl).toFixed(2) : 99, win: +(100 * a.filter(x => x > 0).length / n).toFixed(1) };
}

const answers = new Map();
for (const ln of fs.readFileSync(resFile, 'utf8').split(/\r?\n/)) { if (!ln) continue; const o = JSON.parse(ln); if (o.ok) answers.set(o.id, o); }
let seed = 11; const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const rows = []; let none = 0, total = 0, missing = 0;
for (const c of set.calls) {
  const a = answers.get(c.id); if (!a) continue;
  for (const it of c.items) {
    total++;
    const sig = a.signals.find(s => String(s.pair || '').toUpperCase().replace(/[^A-Z0-9_]/g, '') === it.k);
    if (!sig) { missing++; continue; }
    const act = String(sig.action || '').toUpperCase(); const conf = +sig.conf || 0;
    if (act !== 'BUY' && act !== 'SELL') { none++; continue; }
    const d = act === 'BUY' ? 1 : -1;
    const ai = sim(it.sym, it.t, d), rv = sim(it.sym, it.t, -d), rn = sim(it.sym, it.t, rnd() < 0.5 ? 1 : -1);
    const slope = +((c.prompt.split('=== ' + it.k + ' ===')[1] || '').match(/slope (-?[\d.]+)/) || [0, 0])[1];
    const fs_ = sim(it.sym, it.t, slope >= 0 ? -1 : 1);   // FADE-SLOPE: trivial rule, same moments
    if (!ai || !rv || !rn || !fs_) continue;
    const ny = new Date((it.t + 900 - OFF * 3600) * 1000); const h = ny.getUTCHours();
    rows.push({ conf, d, ai, rv, rn, fsl: fs_, year: ny.getUTCFullYear(), sess: (h >= 19 || h < 3) ? 'ASIA' : h < 8 ? 'LON' : h < 12 ? 'OVL' : 'NYPM', sym: it.sym });
  }
}
const sel = rows.filter(r => r.conf >= MIN);
const line = (name, f, list = sel) => { const n = stat(list.map(r => f(r).net)), g = stat(list.map(r => f(r).gross));
  console.log(`${name.padEnd(10)} net ${n.avgR >= 0 ? '+' : ''}${n.avgR}R t${n.t} PF${n.pf} win${n.win}% n${n.n} | gross ${g.avgR >= 0 ? '+' : ''}${g.avgR}R t${g.t}`); };
console.log(`\nREPLAY SCORE | calls answered ${answers.size}/${set.calls.length} | decisions ${total} | NONE ${none} | unmatched ${missing} | BUY/SELL ${rows.length} | used (conf>=${MIN}) ${sel.length} | comm ${COMM} pip\n`);
line('AI', r => r.ai); line('REVERSE', r => r.rv); line('RANDOM', r => r.rn); line('FADE-SLOPE', r => r.fsl);
console.log('(FADE-SLOPE = sell when EMA20 slope >= 0, buy when < 0 - if REVERSE is not clearly better, the AI adds nothing a 1-line rule cannot do)');
console.log('\nby year (AI net / REVERSE net):');
for (const y of [...new Set(sel.map(r => r.year))].sort()) { const L = sel.filter(r => r.year === y); console.log(`  ${y}  AI ${stat(L.map(r => r.ai.net)).avgR}  REV ${stat(L.map(r => r.rv.net)).avgR}  (n${L.length})`); }
console.log('by session (AI net / REVERSE net / AI gross):');
for (const s of ['ASIA', 'LON', 'OVL', 'NYPM']) { const L = sel.filter(r => r.sess === s); console.log(`  ${s.padEnd(5)} AI ${stat(L.map(r => r.ai.net)).avgR}  REV ${stat(L.map(r => r.rv.net)).avgR}  AIgross ${stat(L.map(r => r.ai.gross)).avgR}  (n${L.length})`); }
console.log('calibration (all BUY/SELL, AI gross / net):');
for (const [lo, hi] of [[0, 50], [50, 60], [60, 70], [70, 80], [80, 101]]) { const L = rows.filter(r => r.conf >= lo && r.conf < hi); console.log(`  ${lo}-${hi - 1}  gross ${stat(L.map(r => r.ai.gross)).avgR}  net ${stat(L.map(r => r.ai.net)).avgR}  t ${stat(L.map(r => r.ai.gross)).t}  (n${L.length})`); }
console.log(`direction split: BUY ${sel.filter(r => r.d > 0).length} / SELL ${sel.filter(r => r.d < 0).length}`);

// Static wiring check for index.html.
// Verifies the step data against the real DOM, the SVG viewBox, and that no
// diagram shapes overlap. Run: node validate.cjs
const fs = require('fs');

const html = fs.readFileSync('index.html', 'utf8');
let fail = 0;
const ok = (c, m) => { if (!c) { console.log('  FAIL  ' + m); fail++; } };

// --- pull the script out of the page and evaluate just the data ---
const blocks = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)];
const js = blocks[blocks.length - 1][1];
const phases = eval('(' + js.match(/const PHASES = (\{[\s\S]*?\n        \});/)[1] + ')');
const steps = eval(js.match(/const stepsData = (\[[\s\S]*?\n        \]);/)[1]);

console.log('phases parsed: ' + Object.keys(phases).length);
console.log('steps parsed:  ' + steps.length);
ok(Object.keys(phases).length === 4, 'expected 4 phases');
ok(steps.length === 6, 'expected 6 steps');

// --- viewBox bounds ---
const [, VW, VH] = html.match(/viewBox="0 0 (\d+) (\d+)"/).map(Number);
console.log('viewBox: ' + VW + 'x' + VH);

// --- ids referenced by the controller must exist in the markup ---
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
[
  'totalStepsBadge', 'currentStepBadge', 'animPacketCircle', 'inspectorPhaseBadge',
  'inspectorStatusCode', 'inspectorTitle', 'inspectorSubtitle', 'inspectorDescription',
  'inspectorSource', 'inspectorTarget', 'inspectorActionsList', 'inspectorJsonPayload',
  'rawJsonContent', 'diagramContainer', 'rawJsonView', 'viewBtnText', 'autoLoopCheck',
  'prevBtn', 'nextBtn', 'playIcon', 'playText', 'speedSlider', 'speedVal',
  'inspectorRole', 'inspectorRoleIcon',
].forEach(id => ok(ids.has(id), 'missing element id: ' + id));

// flow cards are addressed dynamically as prefix + 'Wrap'/'Label'/'List'
['inspectorFlowIn', 'inspectorFlowOut'].forEach(p =>
  ['Wrap', 'Label', 'List'].forEach(sfx =>
    ok(ids.has(p + sfx), 'missing flow element: ' + p + sfx)));

// --- per-step validation ---
const REQ = ['step', 'phase', 'phaseBadgeClass', 'title', 'subtitle', 'statusCode',
  'statusClass', 'role', 'roleIcon', 'roleTone', 'source', 'sourceIcon', 'target',
  'targetIcon', 'description', 'actions', 'arrowId', 'packetPos', 'payload'];

steps.forEach((s, i) => {
  const tag = 'step ' + (i + 1);
  REQ.forEach(k => ok(s[k] !== undefined && s[k] !== null && s[k] !== '', tag + ' missing ' + k));
  ok(s.step === i + 1, tag + ' out of sequence (step=' + s.step + ')');
  ok(phases[s.phase], tag + ' references undefined phase ' + s.phase);
  ok(Array.isArray(s.actions) && s.actions.length >= 3, tag + ' needs >=3 actions');
  ok(s.payload && typeof s.payload === 'object', tag + ' payload not an object');

  // at least one of flowIn / flowOut must be populated
  ok((s.flowIn && s.flowIn.length) || (s.flowOut && s.flowOut.length),
     tag + ' has neither flowIn nor flowOut');
  if (s.flowIn) ok(!!s.flowInLabel, tag + ' flowIn without a label');
  if (s.flowOut) ok(!!s.flowOutLabel, tag + ' flowOut without a label');
  (s.flowIn || []).concat(s.flowOut || []).forEach((t, n) =>
    ok(typeof t === 'string' && t.length, tag + ' flow item ' + n + ' empty'));

  // arrow target exists, is clickable, and dims by default
  ok(ids.has(s.arrowId), tag + ' arrowId not in DOM: ' + s.arrowId);
  const g = html.match(new RegExp('<g id="' + s.arrowId + '"[^>]*>'));
  ok(g && /onclick="goToStep\(\d+\)"/.test(g[0]), tag + ' arrow missing goToStep click');
  ok(g && /opacity-30/.test(g[0]), tag + ' arrow missing default dim state');
  ok(g && /tabindex="0"/.test(g[0]), tag + ' arrow not keyboard focusable');

  // coordinates inside the canvas
  const p = s.packetPos;
  ['startX', 'startY', 'endX', 'endY'].forEach(k => {
    ok(typeof p[k] === 'number', tag + ' packetPos.' + k + ' not numeric');
    ok(p[k] >= 0 && p[k] <= (k.endsWith('X') ? VW : VH), tag + ' packetPos.' + k + ' out of viewBox');
  });

  try { JSON.stringify(s.payload); } catch (e) { ok(false, tag + ' payload not serialisable'); }
});

// --- phase coverage: every phase must have at least one step, and the
//     concurrency pairs (extraction fan, dual output) must share a phase ---
const byPhase = {};
steps.forEach(s => (byPhase[s.phase] ||= []).push(s.step));
Object.keys(phases).forEach(p =>
  ok(byPhase[p] && byPhase[p].length, 'phase ' + p + ' has no steps'));
console.log('steps per phase: ' + Object.entries(byPhase).map(([p, v]) => p + '=[' + v + ']').join(' '));
ok(byPhase[3].length === 2, 'extraction fan should have 2 concurrent branches');
ok(byPhase[4].length === 2, 'dual output should have 2 parallel paths');

// --- fan branches must originate from the same fork node ---
const fanStarts = steps.filter(s => s.phase === 3).map(s => s.packetPos.startX + ',' + s.packetPos.startY);
ok(new Set(fanStarts).size === 1, 'extraction branches do not share a fork origin: ' + fanStarts.join(' / '));

// --- concurrent branches must diverge, not overlap ---
const [b1, b2] = steps.filter(s => s.phase === 3);
ok(b1.packetPos.endX < 500 && b2.packetPos.endX > 500,
   'extraction branches should diverge left and right of the engine');

// --- destination lifeline must actually be used by Path A ---
ok(steps.some(s => s.target.includes('Target Destination')),
   'no step targets the Target Destination actor');

// --- every arrow marker referenced is defined ---
const defined = new Set([...html.matchAll(/marker id="([^"]+)"/g)].map(m => m[1]));
[...new Set([...html.matchAll(/marker-end="url\(#([^)]+)\)/g)].map(m => m[1]))].forEach(m =>
  ok(defined.has(m), 'undefined arrow marker: ' + m));

// --- label boxes must not overlap each other ---
const boxes = [...html.matchAll(/<rect x="(\d+)" y="(\d+)" width="(\d+)" height="(\d+)"/g)]
  .map(m => ({ x: +m[1], y: +m[2], w: +m[3], h: +m[4] }))
  .filter(b => b.h <= 20); // only the small step labels, not actor cards / bands
boxes.forEach((a, i) => boxes.slice(i + 1).forEach(b => {
  const hit = a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  ok(!hit, 'label boxes overlap at (' + a.x + ',' + a.y + ') and (' + b.x + ',' + b.y + ')');
}));
console.log('step label boxes: ' + boxes.length);

// --- every shape must sit inside the viewBox ---
[...html.matchAll(/<(rect|line|circle|text)([^>]*)>/g)].forEach(m => {
  // the packet circle is deliberately parked off-canvas until first render
  if (/id="animPacketCircle"/.test(m[0])) return;
  const attrs = m[2];
  const num = k => { const r = attrs.match(new RegExp('\\b' + k + '="(-?[\\d.]+)"')); return r ? +r[1] : null; };
  ['x', 'y', 'cx', 'cy', 'x1', 'x2', 'y1', 'y2'].forEach(k => {
    const v = num(k);
    if (v === null) return;
    const limit = (k.endsWith('X') || k === 'cx' || k === 'x' || k === 'x1' || k === 'x2') ? VW : VH;
    ok(v >= -2 && v <= limit + 2, `<${m[1]} ${k}="${v}"> outside viewBox`);
  });
});

// --- phase legend chips must point at real steps ---
[...html.matchAll(/<span onclick="goToStep\((\d+)\)"/g)].forEach(m => {
  const n = +m[1];
  ok(n >= 1 && n <= steps.length, 'phase chip points at missing step: ' + n);
});

// --- every JS handler referenced by an inline attribute is defined ---
const definedFns = new Set([...js.matchAll(/function\s+([A-Za-z0-9_$]+)\s*\(/g)].map(m => m[1]));
[...html.matchAll(/\bon(?:click|change|input)="([a-zA-Z0-9_$]+)\(/g)].forEach(m =>
  ok(definedFns.has(m[1]), 'inline handler not defined: ' + m[1] + '()'));
// ...and every id-bearing element the flow renderer builds must be unique
const all = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
const dupes = all.filter((v, i) => all.indexOf(v) !== i);
ok(dupes.length === 0, 'duplicate ids: ' + [...new Set(dupes)].join(', '));

console.log(fail === 0 ? '\nALL CHECKS PASSED' : '\n' + fail + ' CHECK(S) FAILED');
process.exit(fail === 0 ? 0 : 1);

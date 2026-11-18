#!/usr/bin/env node
// Exam-start load test: N students open the same exam within RAMP seconds, then every
// student autosaves every AUTOSAVE seconds until the test ends. Open-loop (arrivals do not
// wait for slow responses), like real students.
//
//   API=<url> node scripts/load-test.mjs --students 3000 --ramp 300 --autosave 30 --hold 120 --run before
//
// Every 10 s the driver publishes what it measured to CloudWatch (namespace ExamPlatform/LoadTest,
// dimension Run=<run>): Requests, Errors5xx, Throttled (429), Rejected4xx, LatencyP95, LatencyMax,
// InFlight. scripts/load-test.sh reads them back with GetMetricStatistics. In real AWS the
// same picture comes from AWS/Lambda ConcurrentExecutions + Throttles and AWS/ApiGateway Latency.
import { execFile } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const API = process.env.API;
const N = Number(arg('students', 3000));
const RAMP = Number(arg('ramp', 300));
const AUTOSAVE = Number(arg('autosave', 30));
const HOLD = Number(arg('hold', 120));
const RUN = arg('run', 'run');
const EXAM = arg('exam', 'dso303-midterm');
const OFFSET = Number(arg('offset', 0)); // each run uses fresh students (lt-0001.. / lt-1001..)
const OUT = arg('out', `/tmp/load-${RUN}.json`);
if (!API) { console.error('set API'); process.exit(2); }

const t0 = Date.now();
const samples = []; // [tSec, route, status, ms]
let inFlight = 0; let maxInFlight = 0;

async function call(route, method, path, user, body) {
  const start = Date.now(); inFlight += 1; maxInFlight = Math.max(maxInFlight, inFlight);
  let status = 0;
  try {
    const r = await fetch(API + path, {
      method,
      headers: { 'x-demo-user': user, 'x-demo-groups': 'students', 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(30000),
    });
    status = r.status;
    const text = await r.text();
    return status < 300 ? JSON.parse(text) : null;
  } catch { status = 599; return null; } finally {
    inFlight -= 1;
    samples.push([(Date.now() - t0) / 1000, route, status, Date.now() - start]);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const endAt = t0 + (RAMP + HOLD) * 1000;

async function student(i) {
  await sleep((i * RAMP * 1000) / N);
  const user = `lt-${String(OFFSET + i + 1).padStart(4, '0')}`;
  await call('GET exam', 'GET', `/exams/${EXAM}`, user);
  const att = await call('POST attempt', 'POST', `/exams/${EXAM}/attempts`, user);
  if (!att) return;
  await sleep(Math.random() * AUTOSAVE * 1000); // students are not in lock-step
  let q = 1;
  while (Date.now() < endAt) {
    await call('PUT autosave', 'PUT', `/attempts/${att.attemptId}/answers`, user,
      { clientTs: Date.now(), answers: [{ questionId: `q${(q % 4) + 1}`, value: `answer ${q}` }] });
    q += 1;
    await sleep(AUTOSAVE * 1000);
  }
}

const pct = (arr, p) => { if (!arr.length) return 0; const s = [...arr].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };

// Publish one 10-second window to CloudWatch.
let published = 0; let pending = 0;
function publish(final = false) {
  const now = (Date.now() - t0) / 1000;
  while (published + 10 <= now || (final && published < now)) {
    const w = samples.filter((s) => s[0] >= published && s[0] < published + 10);
    const lat = w.map((s) => s[3]);
    const ts = new Date(t0 + published * 1000).toISOString();
    const m = (name, value, unit) => ({ MetricName: name, Dimensions: [{ Name: 'Run', Value: RUN }], Timestamp: ts, Value: value, Unit: unit });
    const data = [
      m('Requests', w.length, 'Count'),
      m('Errors5xx', w.filter((s) => s[2] >= 500).length, 'Count'),
      m('Throttled', w.filter((s) => s[2] === 429).length, 'Count'),
      m('Rejected4xx', w.filter((s) => s[2] >= 400 && s[2] < 500 && s[2] !== 429).length, 'Count'),
      m('LatencyP95', pct(lat, 0.95), 'Milliseconds'),
      m('LatencyMax', lat.length ? Math.max(...lat) : 0, 'Milliseconds'),
      m('InFlight', maxInFlight, 'Count'),
    ];
    maxInFlight = inFlight;
    // Asynchronous, so publishing never stalls the request generator.
    pending += 1;
    execFile('aws', ['cloudwatch', 'put-metric-data', '--namespace', 'ExamPlatform/LoadTest', '--metric-data', JSON.stringify(data)],
      (e) => { pending -= 1; if (e) console.error('put-metric-data failed', e.message); });
    published += 10;
  }
}

const timer = setInterval(() => {
  publish();
  const t = Math.round((Date.now() - t0) / 1000);
  const last = samples.filter((s) => s[0] > t - 10);
  const err = last.filter((s) => s[2] >= 500 || s[2] === 429).length;
  process.stdout.write(`  t=${String(t).padStart(3)}s  started=${String(Math.min(N, Math.floor((t / RAMP) * N))).padStart(4)}  ` +
    `req/s=${(last.length / 10).toFixed(1).padStart(6)}  p95=${String(pct(last.map((s) => s[3]), 0.95)).padStart(5)} ms  errors(10s)=${err}  in-flight=${inFlight}\n`);
}, 10000);

console.log(`load test "${RUN}": ${N} students start ${EXAM} within ${RAMP}s, autosave every ${AUTOSAVE}s, hold ${HOLD}s`);
await Promise.all(Array.from({ length: N }, (_, i) => student(i)));
clearInterval(timer);
publish(true);
while (pending > 0) await sleep(200);

const routes = [...new Set(samples.map((s) => s[1]))];
console.log('\nroute            requests    ok   429   5xx  p50 ms  p95 ms  max ms');
for (const r of [...routes, 'ALL']) {
  const w = r === 'ALL' ? samples : samples.filter((s) => s[1] === r);
  const lat = w.map((s) => s[3]);
  console.log(`${r.padEnd(15)} ${String(w.length).padStart(9)} ${String(w.filter((s) => s[2] < 300).length).padStart(5)} ` +
    `${String(w.filter((s) => s[2] === 429).length).padStart(5)} ${String(w.filter((s) => s[2] >= 500).length).padStart(5)} ` +
    `${String(pct(lat, 0.5)).padStart(7)} ${String(pct(lat, 0.95)).padStart(7)} ${String(Math.max(...lat)).padStart(7)}`);
}
const ok = samples.filter((s) => s[2] < 300).length;
console.log(`success rate ${(100 * ok / samples.length).toFixed(2)}%  over ${((Date.now() - t0) / 1000).toFixed(0)}s`);
writeFileSync(OUT, JSON.stringify({ run: RUN, N, RAMP, AUTOSAVE, HOLD, samples }));

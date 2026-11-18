#!/usr/bin/env node
// Background exam traffic for the failure tests: STUDENTS students each autosave every
// INTERVAL seconds, the way the SPA does. A failed save is kept (the SPA keeps it in
// localStorage) and re-sent with the next tick, so we can measure what the server lost.
//
//   API=<url> node exam-traffic.mjs --students 5 --interval 3 --seconds 120 --offset 2900 --out /tmp/traffic.json
// On exit it writes, per student, the attempt id and the last answer value the client produced.
import { writeFileSync } from 'node:fs';

const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const API = process.env.API;
const N = Number(arg('students', 5)); const INTERVAL = Number(arg('interval', 3));
const SECONDS = Number(arg('seconds', 120)); const OFFSET = Number(arg('offset', 2900));
const OUT = arg('out', '/tmp/traffic.json');
const t0 = Date.now();
const log = []; // [t, student, status]
let lastOk = 0; let firstFail = null; let maxGap = 0;

async function req(method, path, user, body) {
  try {
    const r = await fetch(API + path, {
      method, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(25000),
      headers: { 'x-demo-user': user, 'x-demo-groups': 'students', 'content-type': 'application/json' },
    });
    const text = await r.text();
    return { status: r.status, body: r.status < 300 ? JSON.parse(text) : null };
  } catch { return { status: 599, body: null }; }
}

const students = [];
for (let i = 0; i < N; i++) {
  const user = `lt-${String(OFFSET + i + 1).padStart(4, '0')}`;
  let a = await req('POST', '/exams/dso303-midterm/attempts', user);
  while (a.status !== 201) { a = await req('POST', '/exams/dso303-midterm/attempts', user); }
  students.push({ user, attemptId: a.body.attemptId, n: 0, pending: null, lastAcked: null });
}
console.log(`exam traffic: ${N} students autosaving every ${INTERVAL}s for ${SECONDS}s`);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
while (Date.now() - t0 < SECONDS * 1000) {
  const tick = Date.now();
  await Promise.all(students.map(async (s) => {
    s.n += 1;
    s.pending = { questionId: 'q4', value: `answer-v${s.n}`, clientTs: Date.now() }; // newest answer replaces any unsent one
    const r = await req('PUT', `/attempts/${s.attemptId}/answers`, s.user,
      { clientTs: s.pending.clientTs, answers: [{ questionId: s.pending.questionId, value: s.pending.value }] });
    const t = (Date.now() - t0) / 1000;
    log.push([t, s.user, r.status]);
    if (r.status === 200) {
      s.lastAcked = s.pending.value; s.pending = null;
      if (firstFail !== null) { maxGap = Math.max(maxGap, t - firstFail); firstFail = null; }
      lastOk = t;
    } else if (firstFail === null) firstFail = t;
  }));
  const ok = log.filter((l) => l[0] * 1000 >= tick - t0 && l[2] === 200).length;
  console.log(`  t=${String(Math.round((tick - t0) / 1000)).padStart(3)}s  autosaves ok ${ok}/${N}`);
  await sleep(Math.max(0, INTERVAL * 1000 - (Date.now() - tick)));
}
// Final flush: anything still pending is re-sent until accepted (SPA behaviour after recovery).
for (const s of students) {
  while (s.pending) {
    const r = await req('PUT', `/attempts/${s.attemptId}/answers`, s.user,
      { clientTs: s.pending.clientTs, answers: [{ questionId: s.pending.questionId, value: s.pending.value }] });
    if (r.status === 200) { s.lastAcked = s.pending.value; s.pending = null; } else await sleep(2000);
  }
}
const failed = log.filter((l) => l[2] !== 200).length;
console.log(`autosaves sent ${log.length}, failed ${failed}, longest failure window ${maxGap.toFixed(0)}s`);
writeFileSync(OUT, JSON.stringify({ students: students.map((s) => ({ user: s.user, attemptId: s.attemptId, last: s.lastAcked })), sent: log.length, failed, maxGap }));

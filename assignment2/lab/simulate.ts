// Runs the Cloud Architecture Lab engine headlessly against lab/exam-platform.reference.json:
//   walkthrough 1, auto-marking, walkthrough 2 - healthy, then again with us-east-1a (AZ-A) failed.
// Usage: LAB_DIR=/path/to/aws-resilience-simulator node --experimental-strip-types lab/simulate.ts
import { readFileSync } from 'node:fs';

const LAB = process.env.LAB_DIR;
if (!LAB) throw new Error('set LAB_DIR to the AWS Architecture Lab checkout');
const { runSimulation } = await import(`${LAB}/src/engine/simulation/requestSimulator.ts`);
const { createFailure } = await import(`${LAB}/src/engine/failure/propagation.ts`);
const { computeEffectiveArchitectureState } = await import(`${LAB}/src/engine/failure/effectiveState.ts`);

const ref = JSON.parse(readFileSync(new URL('./exam-platform.reference.json', import.meta.url), 'utf8'));
const C = { b: '\x1b[1m', g: '\x1b[32m', r: '\x1b[31m', y: '\x1b[33m', c: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };

// The lab treats SQS as an asynchronous boundary (the producer gets 202 and the trace ends), so
// each queue's consumer half is simulated as its own request. It starts at the consumer Lambda
// that the event source mapping would invoke - the first healthy one, as Lambda does across AZs.
const scenarios = [
  { id: 'w1', name: 'Walkthrough 1a: student opens exam, answers autosave', method: 'PUT', path: '/api/attempts/{id}/answers', start: ['node-student-exam'], trafficLevel: 'very_high' },
  { id: 'w1s', name: 'Walkthrough 1b: submit -> marking queue', method: 'POST', path: 'sqs://marking', start: ['node-sqs-marking'], trafficLevel: 'high' },
  { id: 'w1m', name: 'Walkthrough 1c: marker Lambda writes result to Aurora', method: 'POST', path: '/internal/mark', start: ['node-marker-a', 'node-marker-b'], trafficLevel: 'high' },
  { id: 'w2', name: 'Walkthrough 2a: 40 MB PUT to S3 -> uploads queue', method: 'PUT', path: '/submissions/DSO303/A2/report.pdf', start: ['node-student-upload'], trafficLevel: 'high' },
  { id: 'w2n', name: 'Walkthrough 2b: notifier Lambda records submission (DynamoDB), SES email drawn', method: 'POST', path: '/internal/notify', start: ['node-notifier'], trafficLevel: 'normal' },
];

function run(label: string, nodes: any[], edges: any[]) {
  console.log(`\n${C.b}${C.c}=== ${label} ===${C.x}`);
  let ok = 0;
  for (const sc of scenarios) {
    const startNodeId = sc.start.find(id => nodes.find(n => n.id === id)?.data.health !== 'failed') ?? sc.start[0];
    const s = { ...sc, startNodeId };
    const r = runSimulation(nodes, edges, s);
    const tag = r.success ? `${C.g}PASS${C.x}` : `${C.r}FAIL${C.x}`;
    console.log(`\n${C.b}${s.name}${C.x}  [${tag} HTTP ${r.statusCode}, ${Math.round(r.totalLatencyMs)} ms]`);
    for (const step of r.steps) {
      const st = step.status === 'success' ? C.g : step.status === 'failed' ? C.r : C.y;
      const hop = step.sourceNodeId === step.targetNodeId ? step.sourceNodeName : `${step.sourceNodeName} -> ${step.targetNodeName}`;
      console.log(`  ${st}${String(step.stepNumber).padStart(2)}${C.x} ${hop}  ${C.d}${step.action}${C.x}`);
      if (step.details?.recoveryApplied || /FAILED target|failover|Failover/.test(step.explanation)) {
        console.log(`     ${C.y}> ${step.explanation.slice(0, 230)}${C.x}`);
      }
    }
    console.log(`  ${C.d}summary: ${r.summary}${C.x}`);
    if (r.success) ok++;
  }
  return ok;
}

const healthy = run('Healthy - both AZs', ref.nodes, ref.edges);

const failure = createFailure({ targetResourceId: 'AZ-A', failureType: 'az_failure', severity: 'critical', trigger: 'manual', reason: 'Zone outage (us-east-1a)' });
const state = computeEffectiveArchitectureState(ref.nodes, ref.edges, [failure]);
const impact = state.impacts[0];
const name = (id: string) => ref.nodes.find((n: any) => n.id === id)?.data.label ?? id;
console.log(`\n${C.b}${C.r}*** Failure injected: az_failure AZ-A (us-east-1a) ***${C.x}`);
console.log(`  directly failed : ${impact.directlyFailedNodeIds.map(name).join(', ')}`);
console.log(`  cascaded        : ${impact.cascadingFailedNodeIds.map(name).join(', ') || 'none'}`);
console.log(`  degraded        : ${impact.degradedNodeIds.map(name).join(', ') || 'none'}`);
const failedAfter = run('AZ-A down - only us-east-1b serving', state.nodes, state.edges);

console.log(`\n${C.b}Result:${C.x} healthy ${healthy}/${scenarios.length} passed, AZ-A failure ${failedAfter}/${scenarios.length} passed`);
process.exitCode = healthy === scenarios.length && failedAfter === scenarios.length ? 0 : 1;

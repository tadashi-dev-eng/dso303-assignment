// Exam platform API - one Lambda behind API Gateway HTTP API (payload v2).
import { randomUUID } from 'node:crypto';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, UpdateCommand, GetCommand, PutCommand, QueryCommand } from '@aws-sdk/lib-dynamodb';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { SQSClient, SendMessageCommand, SendMessageBatchCommand } from '@aws-sdk/client-sqs';
import { sql } from './db.mjs';
import { SCHEMA, SEED } from './schema.mjs';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}), { marshallOptions: { removeUndefinedValues: true } });
const s3 = new S3Client({ forcePathStyle: Boolean(process.env.AWS_ENDPOINT_URL) });
const sqs = new SQSClient({});
const {
  ATTEMPTS_TABLE, SUBMISSIONS_TABLE, SUBMISSIONS_BKT, MARKING_QUEUE_URL, NOTIFY_QUEUE_URL,
} = process.env;
const MAX_UPLOAD_BYTES = Number(process.env.MAX_UPLOAD_BYTES || 52428800);
const ALLOWED_TYPES = { pdf: 'application/pdf', zip: 'application/zip' };
const META = '#meta';

const json = (statusCode, body) => ({ statusCode, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
class HttpError extends Error { constructor(code, msg) { super(msg); this.code = code; } }

// Identity comes from the Cognito JWT verified by API Gateway. In the local Floci
// environment (no JWT authorizer) the caller identity is passed as headers.
function identity(event) {
  const claims = event.requestContext?.authorizer?.jwt?.claims;
  if (claims) {
    const groups = String(claims['cognito:groups'] || '').replace(/[\[\]]/g, '').split(/[ ,]+/).filter(Boolean);
    return { sub: claims['custom:user_id'] || claims.sub, groups };
  }
  if (process.env.AWS_ENDPOINT_URL) {
    const h = event.headers || {};
    return { sub: h['x-demo-user'], groups: String(h['x-demo-groups'] || '').split(',').filter(Boolean) };
  }
  throw new HttpError(401, 'unauthenticated');
}
const requireGroup = (who, group) => { if (!who.groups.includes(group)) throw new HttpError(403, `requires ${group}`); };

async function migrate() {
  for (const stmt of [...SCHEMA, ...SEED]) await sql(stmt);
  const [{ n }] = await sql('SELECT count(*)::int AS n FROM questions');
  return { migrated: true, tables: SCHEMA.length, questions: n };
}

// ---- Walkthrough 1: open exam, start attempt, autosave -------------------
async function getExam(examId, who) {
  requireGroup(who, 'students');
  const [exam] = await sql(
    `SELECT exam_id, title, duration_min, to_char(closes_at,'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS closes_at
       FROM exams WHERE exam_id = :id AND now() BETWEEN opens_at AND closes_at`, { id: examId });
  if (!exam) throw new HttpError(404, 'exam not open');
  // answer_key is never selected - students cannot see it.
  const questions = await sql(
    'SELECT question_id, qtype, prompt, options, marks FROM questions WHERE exam_id = :id ORDER BY question_id', { id: examId });
  return { ...exam, questions: questions.map((q) => ({ ...q, options: q.options ? JSON.parse(q.options) : null })) };
}

async function startAttempt(examId, who) {
  requireGroup(who, 'students');
  const attemptId = randomUUID();
  const rows = await sql(
    `INSERT INTO attempts (attempt_id, exam_id, student_id, ends_at)
       SELECT :aid, exam_id, :sid, now() + make_interval(mins => duration_min) FROM exams WHERE exam_id = :eid
     ON CONFLICT (exam_id, student_id) DO UPDATE SET exam_id = EXCLUDED.exam_id
     RETURNING attempt_id, to_char(ends_at,'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS ends_at`,
    { aid: attemptId, sid: who.sub, eid: examId });
  const attempt = rows[0];
  // Meta item lets every autosave be checked in DynamoDB alone (no SQL on the hot path).
  await ddb.send(new PutCommand({
    TableName: ATTEMPTS_TABLE,
    Item: { attemptId: attempt.attempt_id, questionId: META, examId, studentId: who.sub, endsAt: attempt.ends_at, status: 'in-progress' },
    ConditionExpression: 'attribute_not_exists(attemptId)',
  })).catch((e) => { if (e.name !== 'ConditionalCheckFailedException') throw e; });
  return { attemptId: attempt.attempt_id, endsAt: attempt.ends_at, autosaveSeconds: 30 };
}

async function autosave(attemptId, who, body) {
  const meta = (await ddb.send(new GetCommand({ TableName: ATTEMPTS_TABLE, Key: { attemptId, questionId: META } }))).Item;
  if (!meta || meta.studentId !== who.sub) throw new HttpError(404, 'attempt not found');
  if (meta.status !== 'in-progress') throw new HttpError(409, 'attempt already submitted');
  if (Date.now() > Date.parse(meta.endsAt) + 60_000) throw new HttpError(409, 'time is up');
  const clientTs = Number(body.clientTs || Date.now());
  const answers = Array.isArray(body.answers) ? body.answers.slice(0, 200) : [];
  let saved = 0; let stale = 0;
  await Promise.all(answers.map(async (a) => {
    try {
      await ddb.send(new UpdateCommand({
        TableName: ATTEMPTS_TABLE,
        Key: { attemptId, questionId: String(a.questionId) },
        UpdateExpression: 'SET #v = :v, clientTs = :ts, savedAt = :now',
        // Out-of-order retries can never overwrite a newer answer.
        ConditionExpression: 'attribute_not_exists(clientTs) OR clientTs < :ts',
        ExpressionAttributeNames: { '#v': 'value' },
        ExpressionAttributeValues: { ':v': String(a.value).slice(0, 10000), ':ts': clientTs, ':now': new Date().toISOString() },
      }));
      saved += 1;
    } catch (e) { if (e.name === 'ConditionalCheckFailedException') stale += 1; else throw e; }
  }));
  return { attemptId, saved, stale, savedAt: new Date().toISOString() };
}

async function submitAttempt(attemptId, who) {
  const res = await ddb.send(new UpdateCommand({
    TableName: ATTEMPTS_TABLE,
    Key: { attemptId, questionId: META },
    UpdateExpression: 'SET #s = :sub, submittedAt = :now',
    ConditionExpression: 'studentId = :sid AND #s = :ip',
    ExpressionAttributeNames: { '#s': 'status' },
    ExpressionAttributeValues: { ':sub': 'submitted', ':ip': 'in-progress', ':sid': who.sub, ':now': new Date().toISOString() },
    ReturnValues: 'ALL_NEW',
  }));
  await sql('UPDATE attempts SET submitted_at = now() WHERE attempt_id = :id', { id: attemptId });
  await sqs.send(new SendMessageCommand({
    QueueUrl: MARKING_QUEUE_URL,
    MessageBody: JSON.stringify({ attemptId, examId: res.Attributes.examId, studentId: who.sub }),
  }));
  return { attemptId, status: 'submitted', marking: 'queued' };
}

// ---- Walkthrough 2: presigned upload ------------------------------------
async function createUpload(who, body) {
  requireGroup(who, 'students');
  const ext = String(body.fileName || '').split('.').pop().toLowerCase();
  const size = Number(body.size);
  if (!ALLOWED_TYPES[ext]) throw new HttpError(400, 'only PDF or ZIP files are accepted');
  if (!(size > 0 && size <= MAX_UPLOAD_BYTES)) throw new HttpError(413, `file must be 1 byte - ${MAX_UPLOAD_BYTES} bytes`);
  if (!/^[A-Za-z0-9_-]+$/.test(body.courseId || '') || !/^[A-Za-z0-9_-]+$/.test(body.assignmentId || '')) throw new HttpError(400, 'bad course/assignment id');
  const safeName = String(body.fileName).replace(/[^A-Za-z0-9._-]/g, '_');
  const key = `submissions/${body.courseId}/${body.assignmentId}/${who.sub}/${randomUUID()}-${safeName}`;
  // ContentLength and ContentType are part of the signature: S3 rejects a different size or type.
  const url = await getSignedUrl(s3, new PutObjectCommand({
    Bucket: SUBMISSIONS_BKT, Key: key, ContentType: ALLOWED_TYPES[ext], ContentLength: size,
  }), { expiresIn: 900 });
  return { uploadUrl: url, key, method: 'PUT', headers: { 'content-type': ALLOWED_TYPES[ext] }, expiresIn: 900 };
}

async function listSubmissions(courseId, who) {
  requireGroup(who, 'tutors');
  const out = await ddb.send(new QueryCommand({
    TableName: SUBMISSIONS_TABLE, IndexName: 'byCourse',
    KeyConditionExpression: 'courseId = :c', ExpressionAttributeValues: { ':c': courseId },
  }));
  return { courseId, count: out.Count, submissions: out.Items };
}

// ---- Results release -> email via async queue ---------------------------
async function releaseResults(examId, who) {
  requireGroup(who, 'tutors');
  await sql('UPDATE exams SET released = TRUE WHERE exam_id = :id', { id: examId });
  const rows = await sql(
    `SELECT u.email, e.title, r.mcq_score, r.mcq_total, r.status
       FROM results r JOIN attempts a USING (attempt_id) JOIN users u ON u.user_id = a.student_id
       JOIN exams e ON e.exam_id = a.exam_id WHERE a.exam_id = :id`, { id: examId });
  for (let i = 0; i < rows.length; i += 10) {
    await sqs.send(new SendMessageBatchCommand({
      QueueUrl: NOTIFY_QUEUE_URL,
      Entries: rows.slice(i, i + 10).map((r, j) => ({ Id: String(j), MessageBody: JSON.stringify({ type: 'result', ...r }) })),
    }));
  }
  return { examId, released: true, emailsQueued: rows.length };
}

export async function handler(event) {
  if (event.action === 'migrate') return migrate();
  const route = event.routeKey || `${event.requestContext?.http?.method} ${event.rawPath}`;
  const p = event.pathParameters || {};
  const body = event.body ? JSON.parse(event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body) : {};
  try {
    if (route === 'GET /health') {
      const [db] = await sql('SELECT 1 AS ok');
      return json(200, { status: 'ok', db: db.ok === 1 ? 'reachable' : 'unknown', region: process.env.AWS_REGION });
    }
    const who = identity(event);
    switch (route) {
      case 'GET /exams/{examId}': return json(200, await getExam(p.examId, who));
      case 'POST /exams/{examId}/attempts': return json(201, await startAttempt(p.examId, who));
      case 'PUT /attempts/{attemptId}/answers': return json(200, await autosave(p.attemptId, who, body));
      case 'POST /attempts/{attemptId}/submit': return json(202, await submitAttempt(p.attemptId, who));
      case 'POST /uploads': return json(201, await createUpload(who, body));
      case 'GET /courses/{courseId}/submissions': return json(200, await listSubmissions(p.courseId, who));
      case 'POST /exams/{examId}/results/release': return json(202, await releaseResults(p.examId, who));
      default: return json(404, { error: `no route ${route}` });
    }
  } catch (e) {
    if (e instanceof HttpError) return json(e.code, { error: e.message });
    if (e.name === 'ConditionalCheckFailedException') return json(409, { error: 'conflict' });
    console.error(JSON.stringify({ level: 'error', route, message: e.message, name: e.name }));
    return json(500, { error: 'internal error' });
  }
}

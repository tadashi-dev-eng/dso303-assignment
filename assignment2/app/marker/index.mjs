// Auto-marks MCQ questions for submitted attempts (SQS -> Lambda, partial batch failures).
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, QueryCommand } from '@aws-sdk/lib-dynamodb';
import { sql } from './db.mjs';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

async function mark({ attemptId, examId }) {
  const keyRows = await sql(
    'SELECT question_id, qtype, answer_key, marks FROM questions WHERE exam_id = :id', { id: examId });
  const answers = (await ddb.send(new QueryCommand({
    TableName: process.env.ATTEMPTS_TABLE,
    KeyConditionExpression: 'attemptId = :a',
    ExpressionAttributeValues: { ':a': attemptId },
  }))).Items.filter((i) => i.questionId !== '#meta');
  const given = Object.fromEntries(answers.map((a) => [a.questionId, a.value]));

  let score = 0; let total = 0; let hasShort = false;
  for (const q of keyRows) {
    if (q.qtype === 'mcq') {
      total += q.marks;
      if (given[q.question_id] === q.answer_key) score += q.marks;
    } else hasShort = true;
  }
  const status = hasShort ? 'mcq-marked-awaiting-tutor' : 'fully-marked';
  await sql(
    `INSERT INTO results (attempt_id, mcq_score, mcq_total, status) VALUES (:a, :s, :t, :st)
     ON CONFLICT (attempt_id) DO UPDATE SET mcq_score = EXCLUDED.mcq_score, mcq_total = EXCLUDED.mcq_total,
       status = EXCLUDED.status, marked_at = now()`,
    { a: attemptId, s: score, t: total, st: status });
  console.log(JSON.stringify({ level: 'info', event: 'attempt-marked', attemptId, examId, score, total, status, answered: answers.length }));
}

export async function handler(event) {
  const batchItemFailures = [];
  for (const record of event.Records || []) {
    try {
      await mark(JSON.parse(record.body));
    } catch (e) {
      console.error(JSON.stringify({ level: 'error', messageId: record.messageId, message: e.message }));
      batchItemFailures.push({ itemIdentifier: record.messageId }); // retried, then DLQ after 5 tries
    }
  }
  return { batchItemFailures };
}

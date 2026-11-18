// Handles two queues:
//   uploads queue - S3 ObjectCreated events: record the submission and email the course tutor.
//   notify queue  - result-release messages: email each student their result.
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';
import { S3Client, HeadObjectCommand } from '@aws-sdk/client-s3';
import { SESClient, SendEmailCommand } from '@aws-sdk/client-ses';
import { sql } from './db.mjs';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({ forcePathStyle: Boolean(process.env.AWS_ENDPOINT_URL) });
const ses = new SESClient({});

async function email(to, subject, text) {
  const out = await ses.send(new SendEmailCommand({
    Source: process.env.SENDER_EMAIL,
    Destination: { ToAddresses: [to] },
    Message: { Subject: { Data: subject }, Body: { Text: { Data: text } } },
  }));
  return out.MessageId;
}

async function onUpload(s3Record) {
  const bucket = s3Record.s3.bucket.name;
  const key = decodeURIComponent(s3Record.s3.object.key.replace(/\+/g, ' '));
  // submissions/<course>/<assignment>/<student>/<uuid>-<file>
  const [, courseId, assignmentId, studentId, file] = key.split('/');
  const head = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
  const submissionId = file.slice(0, 36);
  await ddb.send(new PutCommand({
    TableName: process.env.SUBMISSIONS_TABLE,
    Item: {
      submissionId, courseId, assignmentId, studentId, key,
      fileName: file.slice(37), sizeBytes: head.ContentLength, contentType: head.ContentType,
      versionId: head.VersionId, receivedAt: new Date().toISOString(),
    },
  }));
  const [tutor] = await sql(
    `SELECT u.email, c.title FROM courses c JOIN users u ON u.user_id = c.tutor_id WHERE c.course_id = :c`, { c: courseId });
  const mb = (head.ContentLength / 1048576).toFixed(1);
  const messageId = tutor ? await email(tutor.email, `[${courseId}] New submission for ${assignmentId}`,
    `${studentId} submitted ${file.slice(37)} (${mb} MB) for ${assignmentId} in ${tutor.title}.`) : null;
  console.log(JSON.stringify({ level: 'info', event: 'submission-recorded', submissionId, courseId, assignmentId, studentId, sizeMB: Number(mb), tutorEmail: tutor?.email, sesMessageId: messageId }));
}

async function onResult(msg) {
  const messageId = await email(msg.email, `Results released: ${msg.title}`,
    `Your MCQ score is ${msg.mcq_score}/${msg.mcq_total} (${msg.status}).`);
  console.log(JSON.stringify({ level: 'info', event: 'result-emailed', to: msg.email, sesMessageId: messageId }));
}

export async function handler(event) {
  const batchItemFailures = [];
  for (const record of event.Records || []) {
    try {
      const body = JSON.parse(record.body);
      if (body.Event === 's3:TestEvent') continue;
      if (Array.isArray(body.Records)) {
        for (const r of body.Records) if (r.eventSource === 'aws:s3') await onUpload(r);
      } else if (body.type === 'result') {
        await onResult(body);
      }
    } catch (e) {
      console.error(JSON.stringify({ level: 'error', messageId: record.messageId, message: e.message }));
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }
  return { batchItemFailures };
}

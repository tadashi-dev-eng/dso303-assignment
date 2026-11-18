// Thin wrapper over the RDS Data API (HTTPS, no persistent connections),
// so thousands of concurrent Lambda instances never exhaust PostgreSQL connections.
import { RDSDataClient, ExecuteStatementCommand } from '@aws-sdk/client-rds-data';

const rds = new RDSDataClient({});

function toField(value) {
  if (value === null || value === undefined) return { isNull: true };
  if (typeof value === 'number') return Number.isInteger(value) ? { longValue: value } : { doubleValue: value };
  if (typeof value === 'boolean') return { booleanValue: value };
  return { stringValue: String(value) };
}

function fromField(field) {
  if (!field || field.isNull) return null;
  if ('stringValue' in field) return field.stringValue;
  if ('longValue' in field) return Number(field.longValue);
  if ('doubleValue' in field) return field.doubleValue;
  if ('booleanValue' in field) return field.booleanValue;
  return null;
}

// Per-invocation counters, read by the api handler for its EMF metrics line.
export const dbStats = { calls: 0, ms: 0 };

export async function sql(text, params = {}) {
  const started = Date.now();
  dbStats.calls += 1;
  const out = await rds.send(new ExecuteStatementCommand({
    resourceArn: process.env.DB_CLUSTER_ARN,
    secretArn: process.env.DB_SECRET_ARN,
    database: process.env.DB_NAME,
    sql: text,
    includeResultMetadata: true,
    parameters: Object.entries(params).map(([name, value]) => ({ name, value: toField(value) })),
  }));
  dbStats.ms += Date.now() - started;
  const cols = (out.columnMetadata || []).map((c) => c.label || c.name);
  return (out.records || []).map((row) => Object.fromEntries(row.map((f, i) => [cols[i] ?? `c${i}`, fromField(f)])));
}

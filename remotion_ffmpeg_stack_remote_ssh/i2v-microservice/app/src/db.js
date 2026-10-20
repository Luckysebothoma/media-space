import pg from 'pg';
const { Pool } = pg;

export const pool = new Pool({
  host:     process.env.PGHOST     || 'db',
  port:     parseInt(process.env.PGPORT || '5432'),
  database: process.env.PGDATABASE || 'i2v_db',
  user:     process.env.PGUSER     || 'i2v',
  password: process.env.PGPASSWORD || 'i2v_pass',
});

pool.on('error', (err) => {
  console.error('[DB] Unexpected pool error', err.message);
});

export async function dbLog(level, message, jobId = null, context = null) {
  try {
    await pool.query(
      `INSERT INTO logs (job_id, level, message, context) VALUES ($1,$2,$3,$4)`,
      [jobId, level, message, context ? JSON.stringify(context) : null]
    );
  } catch (_) {}
}

export async function dbEvent(jobId, eventType, payload = null) {
  try {
    await pool.query(
      `INSERT INTO events (job_id, event_type, payload) VALUES ($1,$2,$3)`,
      [jobId, eventType, payload ? JSON.stringify(payload) : null]
    );
  } catch (_) {}
}

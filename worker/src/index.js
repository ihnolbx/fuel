// Payload columns per table (everything except rev, which is server-assigned).
const TABLES = {
  foods: [
    'id', 'name', 'brand', 'source', 'external_id', 'serving_qty',
    'serving_unit', 'default_unit', 'kcal', 'protein', 'carbs', 'fat',
    'updated_at', 'deleted_at',
  ],
  log_entries: [
    'id', 'local_date', 'logged_at', 'food_id', 'food_name', 'qty', 'unit',
    'kcal', 'protein', 'carbs', 'fat', 'updated_at', 'deleted_at',
  ],
  weight_entries: [
    'id', 'local_date', 'measured_at', 'weight_lbs', 'body_fat_pct', 'notes',
    'updated_at', 'deleted_at',
  ],
  settings: ['id', 'value', 'updated_at', 'deleted_at'],
};

// Build a LWW upsert for a table. rev is injected via subquery so all upserts
// in the same batch() share the rev bumped earlier in the same transaction.
function buildUpsert(table, cols) {
  const allCols = [...cols, 'rev'];
  const placeholders = [
    ...cols.map(() => '?'),
    '(SELECT current_rev FROM sync_state WHERE id=1)',
  ].join(', ');
  // Skip id (cols[0]) in the SET list — never overwrite the PK.
  const setClauses = cols
    .slice(1)
    .map(c => `${c}=excluded.${c}`)
    .concat('rev=excluded.rev')
    .join(', ');
  return (
    `INSERT INTO ${table} (${allCols.join(', ')}) VALUES (${placeholders}) ` +
    `ON CONFLICT(id) DO UPDATE SET ${setClauses} ` +
    `WHERE excluded.updated_at >= ${table}.updated_at`
  );
}

function corsHeaders(origin) {
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Max-Age': '86400',
  };
}

function json(body, status, extraHeaders) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  });
}

export default {
  async fetch(request, env) {
    const cors = corsHeaders(env.PAGES_ORIGIN);

    // OPTIONS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors });
    }

    const url = new URL(request.url);

    if (request.method !== 'POST' || url.pathname !== '/sync') {
      return new Response('Not Found', { status: 404, headers: cors });
    }

    // Bearer token auth
    const authHeader = request.headers.get('Authorization') ?? '';
    if (!authHeader.startsWith('Bearer ') || authHeader.slice(7) !== env.SYNC_TOKEN) {
      return new Response('Unauthorized', { status: 401, headers: cors });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'invalid JSON' }, 400, cors);
    }

    const cursor = body.cursor ?? 0;
    const changes = body.changes ?? {};

    const hasPush = Object.values(changes).some(
      arr => Array.isArray(arr) && arr.length > 0,
    );

    // Build the batch. Execution order within batch() is a single transaction.
    const stmts = [];

    // 1. Bump rev (only when there are incoming rows to write).
    if (hasPush) {
      stmts.push(
        env.DB.prepare('UPDATE sync_state SET current_rev = current_rev + 1 WHERE id = 1'),
      );
    }

    // 2. Upsert each incoming row with LWW guard. rev comes from the subquery
    //    which reads the value already bumped by statement 1.
    for (const [table, cols] of Object.entries(TABLES)) {
      const rows = changes[table] ?? [];
      if (rows.length === 0) continue;
      const sql = buildUpsert(table, cols);
      for (const row of rows) {
        const values = cols.map(c => row[c] ?? null);
        stmts.push(env.DB.prepare(sql).bind(...values));
      }
    }

    // 3. Pull everything above the client's original cursor (includes rows just
    //    written at newRev, plus anything another device wrote since).
    const pullIndices = {};
    for (const table of Object.keys(TABLES)) {
      pullIndices[table] = stmts.length;
      stmts.push(
        env.DB.prepare(`SELECT * FROM ${table} WHERE rev > ? ORDER BY rev`).bind(cursor),
      );
    }

    // 4. Read the final current_rev to return as the new cursor.
    const revIdx = stmts.length;
    stmts.push(env.DB.prepare('SELECT current_rev FROM sync_state WHERE id = 1'));

    let results;
    try {
      results = await env.DB.batch(stmts);
    } catch (err) {
      return json({ error: 'db error', detail: err.message }, 500, cors);
    }

    const newCursor = results[revIdx].results[0].current_rev;
    const responseChanges = {};
    for (const table of Object.keys(TABLES)) {
      responseChanges[table] = results[pullIndices[table]].results;
    }

    return json({ cursor: newCursor, changes: responseChanges }, 200, cors);
  },
};

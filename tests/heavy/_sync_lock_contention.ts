// Hold the real writer lock until every contender has finished. Tiny syncs can
// otherwise finish before a later process starts, producing legitimate winners.
import { PostgresEngine } from '../../src/core/postgres-engine.ts';
import { tryAcquireDbLock } from '../../src/core/db-lock.ts';

const repo = process.argv[2];
const count = Number(process.env.NUM_PARALLEL ?? 4);
if (!repo || !Number.isInteger(count) || count < 2) {
  throw new Error('Pass a fixture repository and NUM_PARALLEL >= 2');
}
const engine = new PostgresEngine();
await engine.connect({ database_url: process.env.DATABASE_URL! });
const lockId = 'gbrain-sync:default';
const children = new Set<ReturnType<typeof Bun.spawn>>();
async function sync() {
  const child = Bun.spawn([process.execPath, 'run', 'src/cli.ts', 'sync',
    '--repo', repo, '--source', 'default', '--no-embed'], {
    stdout: 'pipe', stderr: 'pipe', env: process.env,
  });
  children.add(child);
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill('SIGKILL');
  }, 60_000);
  try {
    const [rc, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    if (timedOut) throw new Error('Sync process exceeded the 60-second timeout');
    return { rc, output: stdout + stderr };
  } finally {
    clearTimeout(timer);
    children.delete(child);
  }
}
let holder: Awaited<ReturnType<typeof tryAcquireDbLock>> = null;
try {
  holder = await tryAcquireDbLock(engine, lockId);
  if (!holder) throw new Error('Fixture writer lock already held');
  const contenders = await Promise.all(Array.from({ length: count - 1 }, sync));
  for (const result of contenders) {
    if (result.rc === 0 || !result.output.includes('Another sync is in progress')) {
      throw new Error(`Contender did not reject held lock (exit ${result.rc}): ${result.output}`);
    }
  }
  await holder.release();
  holder = null;
  const winner = await sync();
  if (winner.rc !== 0) throw new Error(`Sync after release failed: ${winner.output}`);
  const rows = await engine.executeRaw<{ count: string }>(
    'SELECT COUNT(*) AS count FROM gbrain_cycle_locks WHERE id = $1', [lockId]);
  if (Number(rows[0].count) !== 0) throw new Error('Writer lock leaked after sync');
  console.log(`[sync_lock_regression] OK: ${count - 1} contenders rejected while held; sync succeeds after release; no leaked locks`);
} finally {
  for (const child of children) child.kill('SIGKILL');
  await Promise.all([...children].map(child => child.exited));
  await holder?.release();
  await engine.disconnect();
}

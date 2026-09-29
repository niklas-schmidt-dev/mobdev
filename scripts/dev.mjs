import { spawn } from 'node:child_process';
const children = [];
let stopping = false;
function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  for (const child of children) child.kill();
  process.exitCode = code;
}
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => stop());
function run(args, env = {}) {
  const child = spawn(process.execPath, args, { stdio: 'inherit', env: { ...process.env, ...env } });
  children.push(child);
  child.on('exit', code => stop(code ?? 0));
  return child;
}
const { buildNode } = await import('./build-node.mjs');
await buildNode();
run(['node_modules/vite/bin/vite.js', '--host', '127.0.0.1']);
const deadline = Date.now() + 15000;
while (Date.now() < deadline) {
  try { if ((await fetch('http://127.0.0.1:5173')).ok) break; } catch {}
  await new Promise(resolve => setTimeout(resolve, 200));
}
run(['node_modules/electron/cli.js', '.'], { MOBDEV_UI_URL: 'http://127.0.0.1:5173' });

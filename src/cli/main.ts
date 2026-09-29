import { parseArgs } from 'node:util';
import { readFile, writeFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { api } from './client';
import { startServer } from '../server/server';
import { dataDirectory } from '../shared/paths';
import type { Run, Screenshot } from '../shared/schema';

const help = `Mobdev · open-source mobile workbench

  serve [--demo] [--port 4686]   Start local daemon and web UI
  devices                      Refresh and list connected devices
  doctor                       Show device tooling diagnostics
  token                        Print local API token
  tree DEVICE                  Read the visible UI elements
  screenshot DEVICE -o FILE    Save a screenshot (PNG; SVG in demo mode)
  tap DEVICE LABEL             Tap by label or resource ID
  type DEVICE TEXT             Type into the focused field
  launch DEVICE APP_ID         Launch an installed app
  key DEVICE home|back|enter    Send a system key
  action DEVICE JSON           Execute any documented JSON action
  tests                        List saved .mob tests
  run FILE --device DEVICE     Run a local or saved .mob script
    [--params JSON] [--wait]    Supply parameters / wait for result
  runs                         List runs
  cancel RUN_ID                Cancel a queued or active run

MOBDEV_HOME overrides the data directory. MOBDEV_URL / MOBDEV_TOKEN
connect the CLI or MCP process to an existing daemon. Localhost only.
`;
async function main() {
  const { positionals, values } = parseArgs({ allowPositionals: true, options: { help: { type: 'boolean', short: 'h' }, demo: { type: 'boolean' }, port: { type: 'string' }, device: { type: 'string' }, params: { type: 'string' }, wait: { type: 'boolean' }, output: { type: 'string', short: 'o' }, 'no-discovery': { type: 'boolean' } } });
  const [command, first, second] = positionals;
  const print = (value: unknown) => process.stdout.write(JSON.stringify(value, null, 2) + '\n');
  const required = (value: string | undefined, name: string) => { if (!value) throw new Error(`Missing ${name}. Run with --help.`); return value; };
  if (values.help || !command) { process.stdout.write(help); return; }
  if (command === 'serve') {
    const port = Number(values.port ?? 4686); if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid port');
    const candidates = [path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../ui'), path.resolve('dist/ui')];
    let uiDirectory: string | undefined;
    for (const candidate of candidates) { try { await access(path.join(candidate, 'index.html')); uiDirectory = candidate; break; } catch {} }
    const server = await startServer({ directory: dataDirectory(), port, demo: values.demo, uiDirectory, devOrigin: process.env.MOBDEV_DEV_ORIGIN, discovery: !values['no-discovery'] });
    process.stderr.write(`Mobdev ready at ${server.url}\nData: ${server.store.directory}\nGet browser token: mobdev token\n`);
    let stopping = false;
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { if (!stopping) { stopping = true; void server.close().then(() => { process.exitCode = 0; }).catch(error => { process.stderr.write(String(error)); process.exitCode = 1; }); } });
    return;
  }
  if (command === 'token') { process.stdout.write((await readFile(path.join(dataDirectory(), 'token'), 'utf8')).trim() + '\n'); return; }
  if (command === 'devices' || command === 'doctor') { const result = await api<{ devices: unknown[]; diagnostics: unknown[] }>('/devices/refresh', {}); print(command === 'doctor' ? result.diagnostics : result.devices); return; }
  if (command === 'tests' || command === 'runs') { print(await api(`/${command}`)); return; }
  if (command === 'cancel') { print(await api(`/runs/${encodeURIComponent(required(first, 'RUN_ID'))}/cancel`, {})); return; }
  if (command === 'run') {
    const name = required(first, 'FILE'); let source: string | undefined;
    try { source = await readFile(path.resolve(name), 'utf8'); } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
    let run = await api<Run>('/runs', { deviceId: required(values.device, '--device'), name: path.basename(name), source, params: values.params ? JSON.parse(values.params) as unknown : undefined });
    if (values.wait) { while (['running', 'queued'].includes(run.status)) { await new Promise(resolve => setTimeout(resolve, 250)); run = await api<Run>(`/runs/${run.id}`); } if (run.status !== 'passed') process.exitCode = 1; }
    print(run); return;
  }
  const device = encodeURIComponent(required(first, 'DEVICE'));
  if (command === 'tree') { print(await api(`/devices/${device}/tree`)); return; }
  if (command === 'screenshot') { const shot = await api<Screenshot>(`/devices/${device}/screenshot`); const file = values.output ?? `screenshot.${shot.mime === 'image/png' ? 'png' : 'svg'}`; await writeFile(file, Buffer.from(shot.data, 'base64')); print({ file: path.resolve(file), width: shot.width, height: shot.height }); return; }
  if (command === 'action') { print(await api(`/devices/${device}/action`, JSON.parse(required(second, 'JSON')) as unknown)); return; }
  const argument = required(second, 'action argument');
  const action = command === 'tap' ? { action: 'tap', target: argument } : command === 'type' ? { action: 'type', text: argument } : command === 'launch' ? { action: 'launch', appId: argument } : command === 'key' ? { action: 'key', key: argument } : undefined;
  if (!action) throw new Error(`Unknown command: ${command}`);
  print(await api(`/devices/${device}/action`, action));
}
main().catch(error => { process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`); process.exitCode = 1; });

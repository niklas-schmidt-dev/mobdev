import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile, rename, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import type { Run, Settings, TestCase } from '../shared/schema';
import { AppError } from './errors';

export const exampleSource = '# Fern demo · a complete sign-in flow\nlaunch "dev.mobdev.fern"\ntap "Sign in"\ntype "Email" "alex@example.com"\ntap "Continue"\nwait_for "Welcome, alex"\nscreenshot "signed-in"\n';
export function safeName(name: string): string {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,119}$/.test(name) || name.includes('..')) throw new AppError('Use a name containing only letters, numbers, dots, hyphens and underscores');
  return name;
}
async function atomicWrite(file: string, contents: string | Buffer) {
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temp = `${file}.${randomUUID()}.tmp`;
  try { await writeFile(temp, contents, { mode: 0o600 }); await rename(temp, file); }
  finally { await rm(temp, { force: true }); }
}
export class Store {
  settings: Settings = { agent: { baseUrl: 'http://127.0.0.1:11434/v1', model: '' }, connections: [] };
  token = '';
  constructor(public directory: string) {}
  async init() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    for (const name of ['tests', 'runs', 'artifacts', 'baselines']) await mkdir(path.join(this.directory, name), { recursive: true, mode: 0o700 });
    const tokenFile = path.join(this.directory, 'token');
    try { await writeFile(tokenFile, randomBytes(32).toString('hex'), { flag: 'wx', mode: 0o600 }); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; }
    this.token = (await readFile(tokenFile, 'utf8')).trim();
    if (this.token.length < 32) throw new AppError('Invalid API token file. Remove it to generate a new token.');
    try { this.settings = JSON.parse(await readFile(path.join(this.directory, 'settings.json'), 'utf8')) as Settings; }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw new AppError('Could not read settings.json; repair it before starting'); }
    // Runs interrupted by a process exit must not appear live after restart.
    for (const run of await this.runs()) if (run.status === 'running' || run.status === 'queued') await this.saveRun({ ...run, status: 'cancelled', error: 'Daemon stopped before the run finished', finishedAt: new Date().toISOString() });
  }
  async saveSettings(settings: Settings) { await atomicWrite(path.join(this.directory, 'settings.json'), JSON.stringify(settings, null, 2)); this.settings = settings; }
  async tests(): Promise<TestCase[]> {
    const files = (await readdir(path.join(this.directory, 'tests'))).filter(file => file.endsWith('.mob')).sort();
    const { stat } = await import('node:fs/promises');
    return Promise.all(files.map(async name => ({ name, source: await this.readTest(name), updatedAt: (await stat(path.join(this.directory, 'tests', name))).mtime.toISOString() })));
  }
  async readTest(name: string): Promise<string> {
    try { return await readFile(path.join(this.directory, 'tests', safeName(name.endsWith('.mob') ? name : `${name}.mob`)), 'utf8'); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new AppError(`Test not found: ${name}`, 404); throw error; }
  }
  async saveTest(name: string, source: string): Promise<TestCase> {
    const file = safeName(name.endsWith('.mob') ? name : `${name}.mob`);
    await atomicWrite(path.join(this.directory, 'tests', file), source);
    return { name: file, source, updatedAt: new Date().toISOString() };
  }
  async saveRun(run: Run) { await atomicWrite(path.join(this.directory, 'runs', `${safeName(run.id)}.json`), JSON.stringify(run, null, 2)); }
  async runs(): Promise<Run[]> {
    const files = (await readdir(path.join(this.directory, 'runs'))).filter(file => file.endsWith('.json'));
    const runs = await Promise.all(files.map(async file => JSON.parse(await readFile(path.join(this.directory, 'runs', file), 'utf8')) as Run));
    return runs.sort((a,b) => b.startedAt.localeCompare(a.startedAt));
  }
  async artifact(name: string, data: Buffer): Promise<string> { await atomicWrite(path.join(this.directory, 'artifacts', safeName(name)), data); return name; }
  async readArtifact(name: string) { return readFile(path.join(this.directory, 'artifacts', safeName(name))); }
  async baseline(name: string, data?: Buffer) {
    const file = path.join(this.directory, 'baselines', `${safeName(name)}.png`);
    if (data) { await atomicWrite(file, data); return data; }
    try { return await readFile(file); } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new AppError(`Baseline '${name}' does not exist. Capture it explicitly first.`, 404); throw error; }
  }
}

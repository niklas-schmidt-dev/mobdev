import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import type { Device, Screenshot } from '../../shared/schema';
import { command } from '../process';
import { AppError, pause } from '../errors';
import type { Provider } from './provider';

export class SimulatorProvider implements Provider {
  private recording?: { child: ChildProcess; directory: string; output: string; finished: Promise<void> };
  constructor(public device: Device, private udid: string) {}
  async screenshot(signal?: AbortSignal): Promise<Screenshot> {
    const dir = await mkdtemp(path.join(tmpdir(), 'mobdev-shot-'));
    try {
      const file = path.join(dir, 'screen.png');
      await command('xcrun', ['simctl', 'io', this.udid, 'screenshot', file], { signal });
      const data = await readFile(file);
      return { data: data.toString('base64'), mime: 'image/png', width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
    } finally { await rm(dir, { recursive: true, force: true }); }
  }
  private unsupported(): never { throw new AppError('Connect this simulator through Appium XCUITest to enable input and UI inspection. Native simctl supports screenshots, apps, logs and recording.', 422); }
  async tree(): Promise<never> { return this.unsupported(); }
  async tap(): Promise<never> { return this.unsupported(); }
  async type(): Promise<never> { return this.unsupported(); }
  async swipe(): Promise<never> { return this.unsupported(); }
  async key(): Promise<never> { return this.unsupported(); }
  async launch(appId: string, signal?: AbortSignal) { await command('xcrun', ['simctl', 'launch', this.udid, appId], { signal }); }
  async stop(appId: string, signal?: AbortSignal) { await command('xcrun', ['simctl', 'terminate', this.udid, appId], { signal }); }
  async install(file: string, signal?: AbortSignal) { if (!path.isAbsolute(file) || !file.endsWith('.app')) throw new AppError('Provide an absolute simulator .app directory'); await command('xcrun', ['simctl', 'install', this.udid, file], { signal, timeout: 120000 }); }
  async apps(signal?: AbortSignal) {
    const plist = await command('xcrun', ['simctl', 'listapps', this.udid], { signal });
    // simctl emits a plist. plutil is part of macOS and handles binary/XML/OpenStep formats.
    const dir = await mkdtemp(path.join(tmpdir(), 'mobdev-apps-'));
    try {
      const { writeFile } = await import('node:fs/promises');
      const file = path.join(dir, 'apps.plist'); await writeFile(file, plist);
      const json = await command('plutil', ['-convert', 'json', '-o', '-', file], { signal });
      const apps = JSON.parse(json.toString()) as Record<string, { CFBundleDisplayName?: string; CFBundleName?: string }>;
      return Object.entries(apps).map(([id, app]) => ({ id, name: app.CFBundleDisplayName ?? app.CFBundleName ?? id }));
    } finally { await rm(dir, { recursive: true, force: true }); }
  }
  async logs(signal?: AbortSignal) { return (await command('xcrun', ['simctl', 'spawn', this.udid, 'log', 'show', '--last', '1m', '--style', 'compact', '--level', 'error'], { signal, timeout: 15000 })).toString().slice(-100000); }
  async startRecording() {
    if (this.recording) throw new AppError('Recording already running', 409);
    const directory = await mkdtemp(path.join(tmpdir(), 'mobdev-video-'));
    const output = path.join(directory, 'recording.mp4');
    const child = spawn('xcrun', ['simctl', 'io', this.udid, 'recordVideo', '--codec=h264', output], { stdio: ['ignore', 'ignore', 'pipe'] });
    let error = ''; child.stderr.on('data', chunk => { error += String(chunk); });
    const finished = new Promise<void>((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => code === 0 || signal === 'SIGINT' ? resolve() : reject(new AppError(error || 'Recording failed', 502)));
    });
    finished.catch(() => {});
    this.recording = { child, directory, output, finished }; this.device.recording = true;
    await pause(350);
    if (child.exitCode !== null) { this.recording = undefined; this.device.recording = false; try { await finished; } finally { await rm(directory, { recursive: true, force: true }); } }
  }
  async stopRecording() {
    const recording = this.recording;
    if (!recording) throw new AppError('No recording is running', 409);
    recording.child.kill('SIGINT');
    const killTimer = setTimeout(() => recording.child.kill('SIGKILL'), 10000);
    try { await recording.finished; return await readFile(recording.output); }
    finally { clearTimeout(killTimer); this.recording = undefined; this.device.recording = false; await rm(recording.directory, { recursive: true, force: true }); }
  }
  async close() { if (this.recording) await this.stopRecording().catch(() => {}); }
}

export function parseSimulators(output: string): Device[] {
  const data = JSON.parse(output) as { devices: Record<string, Array<{ udid: string; name: string; state: string; isAvailable: boolean }>> };
  return Object.entries(data.devices).flatMap(([runtime, devices]) => devices.filter(device => device.isAvailable && device.state === 'Booted').map(device => ({ id: `simulator:${device.udid}`, hardwareId: device.udid, name: device.name, version: runtime.split('iOS-')[1]?.replaceAll('-', '.'), platform: 'ios' as const, provider: 'simulator' as const, kind: 'simulator' as const, status: 'ready' as const, capabilities: ['screenshot', 'apps', 'install', 'logs', 'record'] as Device['capabilities'] })));
}

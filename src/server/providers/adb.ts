import { randomUUID } from 'node:crypto';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import type { Device, Screenshot } from '../../shared/schema';
import { command, shellQuote } from '../process';
import { parseElements } from '../elements';
import { AppError, pause } from '../errors';
import type { Provider } from './provider';

export class AdbProvider implements Provider {
  private recording?: { pid: string; file: string };
  constructor(public device: Device, private executable: string, private serial: string) {}
  private adb(args: string[], signal?: AbortSignal, timeout?: number) { return command(this.executable, ['-s', this.serial, ...args], { signal, timeout }); }
  private shell(args: string[], signal?: AbortSignal) { return this.adb(['shell', args.map(shellQuote).join(' ')], signal); }
  async screenshot(signal?: AbortSignal): Promise<Screenshot> {
    const data = await this.adb(['exec-out', 'screencap', '-p'], signal);
    if (!data.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) throw new AppError('ADB returned an invalid screenshot', 502);
    return { data: data.toString('base64'), mime: 'image/png', width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
  }
  async tree(signal?: AbortSignal) {
    const file = `/sdcard/mobdev-tree-${randomUUID()}.xml`;
    try {
      await this.shell(['uiautomator', 'dump', file], signal);
      return parseElements((await this.shell(['cat', file], signal)).toString());
    } finally { await this.shell(['rm', '-f', file]).catch(() => {}); }
  }
  async tap(x: number, y: number, signal?: AbortSignal) { await this.shell(['input', 'tap', String(x), String(y)], signal); }
  async type(text: string, signal?: AbortSignal) {
    if (/[^\x20-\x7e]/.test(text) || text.includes('%s')) throw new AppError('Direct ADB text input supports printable ASCII without literal %s. Use an Appium UiAutomator2 connection for Unicode input.');
    await this.shell(['input', 'text', text.replaceAll(' ', '%s')], signal);
  }
  async swipe(x: number, y: number, toX: number, toY: number, duration: number, signal?: AbortSignal) { await this.shell(['input', 'swipe', ...[x,y,toX,toY,duration].map(String)], signal); }
  async key(key: 'home'|'back'|'enter', signal?: AbortSignal) { await this.shell(['input', 'keyevent', { home: '3', back: '4', enter: '66' }[key]], signal); }
  private appId(value: string) { if (!/^[a-zA-Z][\w.]+$/.test(value)) throw new AppError('Expected an Android package ID'); return value; }
  async launch(appId: string, signal?: AbortSignal) { await this.shell(['monkey', '-p', this.appId(appId), '-c', 'android.intent.category.LAUNCHER', '1'], signal); }
  async stop(appId: string, signal?: AbortSignal) { await this.shell(['am', 'force-stop', this.appId(appId)], signal); }
  async install(file: string, signal?: AbortSignal) { if (!path.isAbsolute(file) || !file.endsWith('.apk')) throw new AppError('Provide an absolute .apk path'); await this.adb(['install', '-r', file], signal, 120000); }
  async apps(signal?: AbortSignal) { return (await this.shell(['pm', 'list', 'packages'], signal)).toString().split(/\r?\n/).filter(line => line.startsWith('package:')).map(line => ({ id: line.slice(8).trim(), name: line.slice(8).trim() })); }
  async logs(signal?: AbortSignal) { return (await this.adb(['logcat', '-d', '-t', '200', '-v', 'brief'], signal)).toString(); }
  async startRecording(signal?: AbortSignal) {
    if (this.recording) throw new AppError('Recording is already running', 409);
    const file = `/sdcard/mobdev-${randomUUID()}.mp4`;
    const pid = (await this.adb(['shell', `screenrecord --time-limit 180 ${shellQuote(file)} >/dev/null 2>&1 & echo $!`], signal)).toString().trim();
    if (!/^\d+$/.test(pid)) throw new AppError('Could not start Android screen recording', 502);
    this.recording = { pid, file }; this.device.recording = true;
  }
  async stopRecording() {
    const recording = this.recording;
    if (!recording) throw new AppError('No recording is running', 409);
    await this.shell(['kill', '-2', recording.pid]).catch(() => {});
    await pause(800);
    const dir = await mkdtemp(path.join(tmpdir(), 'mobdev-record-'));
    try {
      const output = path.join(dir, 'recording.mp4');
      await this.adb(['pull', recording.file, output], undefined, 120000);
      return await readFile(output);
    } finally {
      this.recording = undefined; this.device.recording = false;
      await this.shell(['rm', '-f', recording.file]).catch(() => {});
      await rm(dir, { recursive: true, force: true });
    }
  }
  async metrics(appId: string, signal?: AbortSignal) {
    const id = this.appId(appId);
    const [memory, graphics] = await Promise.all([this.shell(['dumpsys', 'meminfo', id], signal), this.shell(['dumpsys', 'gfxinfo', id], signal)]);
    const result: Record<string, number> = {};
    const pss = memory.toString().match(/TOTAL PSS:\s*(\d+)/) ?? memory.toString().match(/TOTAL\s+(\d+)/);
    const jank = graphics.toString().match(/Janky frames:\s*\d+\s*\(([\d.]+)%\)/);
    if (pss) result.memory_mb = Number(pss[1]) / 1024;
    if (jank) result.jank_percent = Number(jank[1]);
    if (!Object.keys(result).length) throw new AppError(`No performance data for ${id}. Launch the app first.`, 422);
    return result;
  }
  async close() { if (this.recording) await this.stopRecording().catch(() => {}); }
}

export function parseAdbDevices(output: string): Device[] {
  return output.split(/\r?\n/).flatMap(line => {
    const match = line.match(/^(\S+)\s+(device|offline|unauthorized)\b(.*)$/);
    if (!match) return [];
    const serial = match[1]!;
    const name = match[3]?.match(/model:(\S+)/)?.[1]?.replaceAll('_', ' ') ?? serial;
    return [{ id: `adb:${serial}`, hardwareId: serial, name, platform: 'android' as const, provider: 'adb' as const, kind: serial.startsWith('emulator-') ? 'emulator' as const : 'physical' as const, status: match[2] === 'device' ? 'ready' as const : match[2] as 'offline'|'unauthorized', capabilities: ['screenshot','input','tree','apps','install','logs','record','performance'] }];
  });
}

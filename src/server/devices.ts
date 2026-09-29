import { randomUUID } from 'node:crypto';
import type { ConnectionInput, Device, Diagnostic } from '../shared/schema';
import { command, adbPath } from './process';
import { AppError, errorMessage, aborted } from './errors';
import { AdbProvider, parseAdbDevices } from './providers/adb';
import { SimulatorProvider, parseSimulators } from './providers/simulator';
import { AppiumProvider } from './providers/appium';
import { DemoProvider } from './providers/demo';
import type { Provider } from './providers/provider';

export class Devices {
  providers = new Map<string, Provider>();
  diagnostics: Diagnostic[] = [];
  private discovery?: Promise<Device[]>;
  private queues = new Map<string, Promise<unknown>>();
  enableDemo() { const existing = this.providers.get('demo:android'); if (!existing) { const provider = new DemoProvider(); this.providers.set(provider.device.id, provider); } }
  async discover(): Promise<Device[]> {
    if (this.discovery) return this.discovery;
    this.discovery = this.performDiscovery();
    try { return await this.discovery; } finally { this.discovery = undefined; }
  }
  private async performDiscovery() {
    const executable = await adbPath();
    const result = await Promise.allSettled([
      command(executable, ['devices', '-l'], { timeout: 7000 }).then(buffer => parseAdbDevices(buffer.toString())),
      process.platform === 'darwin' ? command('xcrun', ['simctl', 'list', 'devices', 'booted', '--json'], { timeout: 10000 }).then(buffer => parseSimulators(buffer.toString())) : Promise.resolve([]),
    ]);
    this.diagnostics = result.map((r, i) => ({ name: i === 0 ? 'Android / ADB' : 'iOS / Xcode', available: r.status === 'fulfilled' && (i === 0 || process.platform === 'darwin'), detail: i === 1 && process.platform !== 'darwin' ? 'Local simulators require macOS. Connect to a Mac with Appium for iOS.' : r.status === 'fulfilled' ? `${r.value.length} device(s) detected` : errorMessage(r.reason) }));
    const discovered = result.flatMap(r => r.status === 'fulfilled' ? r.value : []);
    const ids = new Set(discovered.map(d => d.id));
    for (const [id, provider] of this.providers) if (['adb', 'simulator'].includes(provider.device.provider) && !ids.has(id)) provider.device.status = 'offline';
    for (const device of discovered) {
      const current = this.providers.get(device.id);
      if (current) { current.device = { ...device, recording: current.device.recording }; continue; }
      this.providers.set(device.id, device.provider === 'adb' ? new AdbProvider(device, executable, device.id.slice(4)) : new SimulatorProvider(device, device.id.slice(10)));
    }
    return this.list();
  }
  list() { return [...this.providers.values()].map(p => p.device); }
  get(id: string): Provider {
    const provider = this.providers.get(id);
    if (!provider) throw new AppError(`Unknown device: ${id}`, 404);
    if (provider.device.status !== 'ready') throw new AppError(`Device is ${provider.device.status}. Check its connection and unlock it.`, 409);
    return provider;
  }
  async connect(connection: ConnectionInput, id: string = randomUUID()) {
    const device: Device = { id: `appium:${id}`, name: connection.name, platform: connection.platform, provider: 'appium', hardwareId: typeof connection.capabilities['appium:udid'] === 'string' ? connection.capabilities['appium:udid'] : undefined, kind: 'remote', status: 'ready', capabilities: ['screenshot','input','tree','install','logs','record','web'] };
    if (this.providers.has(device.id)) throw new AppError('This connection is already open', 409);
    const provider = new AppiumProvider(device, connection);
    await provider.connect();
    this.providers.set(device.id, provider);
    return device;
  }
  async disconnect(id: string) { await this.exclusive(id, async provider => { await provider.close?.(); this.providers.delete(id); }); }
  async exclusive<T>(id: string, work: (provider: Provider) => Promise<T>, signal?: AbortSignal): Promise<T> {
    const device = this.get(id).device;
    const key = device.hardwareId ? `${device.platform}:${device.hardwareId}` : id;
    const previous = this.queues.get(key) ?? Promise.resolve();
    const current = previous.catch(() => {}).then(() => { aborted(signal); return work(this.get(id)); });
    this.queues.set(key, current);
    try { return await current; } finally { if (this.queues.get(key) === current) this.queues.delete(key); }
  }
  async close() { await Promise.allSettled([...this.queues.values()]); await Promise.allSettled([...this.providers.values()].map(p => p.close?.())); }
}

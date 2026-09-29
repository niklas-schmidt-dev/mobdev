import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { PNG } from 'pngjs';
import { DemoProvider } from '../src/server/providers/demo';
import { Devices } from '../src/server/devices';
import { Runner } from '../src/server/runner';
import { Store } from '../src/server/store';
import type { Screenshot } from '../src/shared/schema';

test('known hardware aliases share one queue; different hardware does not', async () => {
  const devices = new Devices();
  const first = new DemoProvider(); first.device = { ...first.device, id: 'adb:serial', hardwareId: 'serial' };
  const alias = new DemoProvider(); alias.device = { ...alias.device, id: 'appium:alias', hardwareId: 'serial' };
  const other = new DemoProvider(); other.device = { ...other.device, id: 'adb:other', hardwareId: 'other' };
  for (const provider of [first, alias, other]) devices.providers.set(provider.device.id, provider);
  const order: string[] = []; let release: () => void = () => {};
  const gate = new Promise<void>(resolve => { release = resolve; });
  const one = devices.exclusive(first.device.id, async () => { order.push('first:start'); await gate; order.push('first:end'); });
  const two = devices.exclusive(alias.device.id, async () => { order.push('alias'); });
  await devices.exclusive(other.device.id, async () => { order.push('other'); });
  assert.deepEqual(order, ['first:start', 'other']); release(); await Promise.all([one,two]); assert.deepEqual(order, ['first:start','other','first:end','alias']);
});

test('visual baselines require explicit approval, compare pixels and produce differences', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'mobdev-baseline-')); const store = new Store(directory); await store.init();
  const devices = new Devices();
  class PixelDevice extends DemoProvider {
    changed = false;
    override async screenshot(): Promise<Screenshot> { const png = new PNG({ width: 20, height: 20 }); png.data.fill(this.changed ? 0 : 255); for (let index = 3; index < png.data.length; index += 4) png.data[index] = 255; return { data: PNG.sync.write(png).toString('base64'), mime: 'image/png', width: 20, height: 20 }; }
  }
  const device = new PixelDevice(); devices.providers.set(device.device.id, device); const runner = new Runner(devices,store);
  t.after(async () => { await runner.close(); await devices.close(); await rm(directory, { recursive:true, force:true }); });
  const missing = await runner.start({ deviceId: device.device.id, source: 'assert_baseline "home"' });
  assert.match((await runner.wait(missing.id)).error!, /does not exist/);
  await store.baseline('home', Buffer.from((await device.screenshot()).data, 'base64'));
  const same = await runner.start({ deviceId: device.device.id, source: 'assert_baseline "home" 0' }); assert.equal((await runner.wait(same.id)).status, 'passed');
  device.changed = true;
  const changed = await runner.start({ deviceId: device.device.id, source: 'assert_baseline "home" 0.01' }); const result = await runner.wait(changed.id);
  assert.equal(result.status, 'failed'); assert.match(result.error!, /100.00%/); assert.ok(result.artifacts.some(name => name.endsWith('-diff.png')));
});

test('unsupported metrics cannot accidentally pass performance assertions', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'mobdev-metrics-')); const store = new Store(directory); await store.init(); const devices = new Devices(); devices.enableDemo(); const runner = new Runner(devices, store);
  t.after(async () => { await runner.close(); await devices.close(); await rm(directory, { recursive:true, force:true }); });
  const absent = await runner.start({ deviceId: 'demo:android', source: 'assert_perf memory_mb < 220' }); assert.equal((await runner.wait(absent.id)).status, 'failed');
  const unsupported = await runner.start({ deviceId: 'demo:android', source: 'measure_perf "dev.mobdev.fern"' }); assert.match((await runner.wait(unsupported.id)).error!, /available for direct ADB/);
});

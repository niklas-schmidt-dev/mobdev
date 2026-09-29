import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { PNG } from 'pngjs';
import { parseAdbDevices } from '../src/server/providers/adb';
import { parseSimulators } from '../src/server/providers/simulator';
import { AppiumProvider } from '../src/server/providers/appium';
import type { Device } from '../src/shared/schema';

test('ADB reports unauthorized and offline devices honestly', () => {
  const devices = parseAdbDevices('List of devices attached\nemulator-5554 device product:sdk model:Pixel_9 transport_id:1\nSERIAL unauthorized usb:1\nHOST:5555 offline\n');
  assert.equal(devices.length, 3); assert.equal(devices[0]?.name, 'Pixel 9'); assert.equal(devices[0]?.kind, 'emulator'); assert.equal(devices[1]?.status, 'unauthorized'); assert.equal(devices[2]?.status, 'offline');
});
test('only booted and available iOS simulators are discovered', () => {
  const devices = parseSimulators(JSON.stringify({ devices: { 'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [{ udid: 'ABC', name: 'iPhone', state: 'Booted', isAvailable: true }, { udid: 'DEF', name: 'Other', state: 'Shutdown', isAvailable: true }] } }));
  assert.equal(devices.length, 1); assert.equal(devices[0]?.version, '18.5'); assert.ok(!devices[0]?.capabilities.includes('input'));
});
test('Appium uses W3C sessions, logical coordinates, safe actions and restores web context', async t => {
  const received: Array<{ method: string; route: string; body: unknown; auth?: string }> = [];
  const png = PNG.sync.write(new PNG({ width: 200, height: 400 })).toString('base64');
  const server = http.createServer(async (request, response) => {
    let body = ''; for await (const chunk of request) body += String(chunk);
    received.push({ method: request.method!, route: request.url!, body: body ? JSON.parse(body) as unknown : undefined, auth: request.headers.authorization });
    const route = request.url!;
    const value: unknown = route === '/wd/hub/session' ? { sessionId: 'test-session' } : route.endsWith('/screenshot') ? png : route.endsWith('/window/rect') ? { width: 100, height: 200 } : route.endsWith('/contexts') ? ['NATIVE_APP','WEBVIEW_test'] : route.endsWith('/context') && request.method === 'GET' ? 'NATIVE_APP' : route.endsWith('/execute/sync') ? 'page title' : null;
    response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({ value }));
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise<void>(resolve => server.close(() => resolve())); });
  const address = server.address(); assert.ok(address && typeof address !== 'string');
  const device: Device = { id: 'appium:test', name: 'Test', platform: 'ios', provider: 'appium', kind: 'remote', status: 'ready', capabilities: ['screenshot','input','tree'] };
  const provider = new AppiumProvider(device, { name: 'Test', url: `http://user:secret@127.0.0.1:${address.port}/wd/hub`, platform: 'ios', capabilities: { 'appium:udid': 'ABC' } });
  await provider.connect();
  assert.equal((received[0]?.body as { capabilities: { alwaysMatch: Record<string, unknown> } }).capabilities.alwaysMatch['appium:noReset'], true);
  const shot = await provider.screenshot(); assert.equal(shot.width, 100); assert.equal(shot.height, 200);
  await provider.tap(30, 40); assert.ok(received.some(r => r.method === 'DELETE' && r.route.endsWith('/actions')));
  await provider.type('Grüße'); assert.ok(JSON.stringify(received).includes('ü'));
  assert.equal(await provider.web('WEBVIEW_test', 'return document.title'), 'page title');
  assert.deepEqual(received.at(-1)?.body, { name: 'NATIVE_APP' });
  await provider.close(); assert.equal(received.at(-1)?.route, '/wd/hub/session/test-session'); assert.equal(received.at(-1)?.method, 'DELETE');
  assert.ok(received.every(r => r.auth === `Basic ${Buffer.from('user:secret').toString('base64')}`));
});

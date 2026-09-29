import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { startServer } from '../src/server/server';
import { exampleSource } from '../src/server/store';
import { DemoProvider } from '../src/server/providers/demo';
import { toScript } from '../src/server/dsl';

test('HTTP API, test execution and persistent evidence', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'mobdev-test-'));
  const service = await startServer({ directory, port: 0, demo: true, discovery: false });
  const request = async (route: string, data?: unknown, method = data === undefined ? 'GET' : 'POST', headers: Record<string,string> = {}) => fetch(`${service.url}${route}`, { method, headers: { Authorization: `Bearer ${service.token}`, 'Content-Type': 'application/json', ...headers }, body: data === undefined ? undefined : JSON.stringify(data) });
  t.after(async () => { await service.close(); await rm(directory, { recursive: true, force: true }); });
  await t.test('no device data without a token; foreign Origin and Host are rejected', async () => {
    assert.equal((await fetch(`${service.url}/api/v1/devices`)).status, 401);
    assert.equal((await request('/api/v1/devices', undefined, 'GET', { Origin: 'https://evil.example' })).status, 403);
    const hostStatus = await new Promise<number | undefined>((resolve, reject) => { const req = http.get(`${service.url}/api/v1/devices`, { headers: { Host: 'evil.example', Authorization: `Bearer ${service.token}` } }, response => { response.resume(); resolve(response.statusCode); }); req.on('error', reject); });
    assert.equal(hostStatus, 403);
    assert.equal((await request('/api/v1/devices', undefined, 'GET', { Origin: service.url })).status, 200);
    assert.equal((await fetch(`${service.url}/health`)).status, 200);
  });
  await t.test('demo is explicitly labeled and does not advertise recording or performance', async () => {
    const result = await (await request('/api/v1/devices')).json() as { devices: Array<{ kind: string; capabilities: string[] }> };
    assert.equal(result.devices[0]?.kind, 'demo'); assert.ok(!result.devices[0]?.capabilities.includes('performance'));
  });
  await t.test('a real HTTP run drives the demo state and saves a screenshot', async () => {
    const response = await request('/api/v1/runs', { deviceId: 'demo:android', source: exampleSource, name: 'smoke.mob' });
    assert.equal(response.status, 202);
    const started = await response.json() as { id: string };
    const run = await service.runner.wait(started.id);
    assert.equal(run.status, 'passed'); assert.equal(run.steps.length, 6); assert.equal(run.artifacts.length, 1);
    const artifact = await request(`/api/v1/artifacts/${run.artifacts[0]}`);
    assert.equal(artifact.status, 200); assert.match(artifact.headers.get('content-disposition')!, /attachment/); assert.match(await artifact.text(), /Welcome, alex/);
    assert.match(run.source!, /wait_for "Welcome, alex"/);
  });
  await t.test('failed assertions persist step failure and failure evidence', async () => {
    const start = await service.runner.start({ deviceId: 'demo:android', source: 'assert "Missing button"\nassert "Never executed"' });
    const run = await service.runner.wait(start.id);
    assert.equal(run.status, 'failed'); assert.equal(run.steps[0]?.status, 'failed'); assert.match(run.error!, /Element not found/);
    assert.equal(run.steps.length, 1); assert.equal(run.artifacts.length, 2); assert.match(run.source!, /Never executed/);
  });
  await t.test('scripts on the same device never interleave, and cancellation unblocks the queue', async () => {
    const first = await service.runner.start({ deviceId: 'demo:android', source: 'wait 5000' });
    const second = await service.runner.start({ deviceId: 'demo:android', source: 'launch "dev.mobdev.fern"\nassert "Sign in"' });
    assert.equal((await service.runner.get(second.id)).status, 'queued');
    service.runner.cancel(first.id);
    assert.equal((await service.runner.wait(first.id)).status, 'cancelled');
    assert.equal((await service.runner.wait(second.id)).status, 'passed');
  });
  await t.test('nested includes detect cycles and preserve the full script', async () => {
    await service.store.saveTest('a.mob', 'run "b.mob"'); await service.store.saveTest('b.mob', 'run "a.mob"');
    const run = await service.runner.start({ deviceId: 'demo:android', name: 'a.mob' });
    assert.match((await service.runner.wait(run.id)).error!, /Recursive include/);
  });
  await t.test('parameterized saved flow can be called as an HTTP API', async () => {
    await service.store.saveTest('greeting.mob', 'launch "dev.mobdev.fern"\ntap "Sign in"\ntype "Email" "${email}"\ntap "Continue"\nextract greeting "welcome"');
    const response = await request('/api/v1/apis/run/greeting', { deviceId: 'demo:android', params: { email: 'sam@example.com' } });
    assert.equal(response.status, 200);
    const data = await response.json() as { values: { greeting: string } }; assert.equal(data.values.greeting, 'Welcome, sam');
  });
  await t.test('suite runs across independent devices and validates before scheduling', async () => {
    const second = new DemoProvider(); second.device = { ...second.device, id: 'demo:second', name: 'Second demo' }; service.devices.providers.set(second.device.id, second);
    await service.store.saveTest('suite.mob', exampleSource);
    const invalid = await request('/api/v1/suites', { deviceIds: ['demo:android'], names: ['suite.mob', 'missing.mob'] });
    assert.equal(invalid.status, 404);
    const response = await request('/api/v1/suites', { deviceIds: ['demo:android', 'demo:second'], names: ['suite.mob'] });
    const runs = await response.json() as Array<{ id: string }>;
    assert.equal(runs.length, 2); assert.deepEqual((await Promise.all(runs.map(run => service.runner.wait(run.id)))).map(run => run.status), ['passed','passed']);
  });
  await t.test('invalid scripts, missing coordinates and traversal fail explicitly', async () => {
    assert.equal((await request('/api/v1/tests', { name: '../bad.mob', source: 'wait 1' }, 'PUT')).status, 400);
    assert.equal((await request('/api/v1/tests', { name: 'bad.mob', source: 'unknown' }, 'PUT')).status, 400);
    assert.equal((await request('/api/v1/devices/demo:android/action', { action: 'tap' })).status, 400);
    assert.equal((await request('/api/v1/devices/demo:android/action', { action: 'tap', x: -1, y: 10 })).status, 400);
  });
  await t.test('saved model keys and connection passwords never appear in settings responses', async () => {
    await service.store.saveSettings({ agent: { baseUrl: 'http://localhost:11434/v1', model: 'test', apiKey: 'TOP_SECRET' }, connections: [{ id: 'example', name: 'Lab', url: 'http://user:SECRET@example.test:4723', platform: 'ios', capabilities: { token: 'CAP_SECRET' } }] });
    const result = await (await request('/api/v1/settings')).text();
    assert.ok(!result.includes('SECRET')); assert.ok(!result.includes('user:')); assert.match(result, /hasKey/);
  });
});

test('bounded built-in agent observes, acts, reports and exports a script', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'mobdev-agent-'));
  const responses = [{ steps: [{ action: 'tap', target: 'Sign in' }] }, { steps: [], report: 'Observed the Email field after tapping Sign in.' }];
  const requests: unknown[] = [];
  const model = http.createServer(async (request, response) => { let body = ''; for await (const chunk of request) body += String(chunk); requests.push(JSON.parse(body) as unknown); response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({ choices: [{ message: { content: JSON.stringify(responses.shift()) } }] })); });
  await new Promise<void>(resolve => model.listen(0, '127.0.0.1', resolve));
  const address = model.address(); assert.ok(address && typeof address !== 'string');
  const service = await startServer({ directory, port: 0, demo: true, discovery: false });
  t.after(async () => { await service.close(); await new Promise<void>(resolve => model.close(() => resolve())); await rm(directory, { recursive: true, force: true }); });
  await service.store.saveSettings({ ...service.store.settings, agent: { baseUrl: `http://127.0.0.1:${address.port}/v1`, model: 'test' } });
  const run = await service.agent.explore('demo:android', 'Open sign in and inspect the fields');
  const finished = await service.runner.wait(run.id);
  assert.equal(finished.status, 'passed'); assert.equal(requests.length, 2); assert.match(JSON.stringify(requests[1]), /Email/); assert.match(finished.report!, /Observed/);
  assert.equal((await service.agent.exportRun(run.id)).source, toScript([{ action: 'tap', target: 'Sign in' }]));
});

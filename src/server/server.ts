import http, { type IncomingMessage, type ServerResponse } from 'node:http';
import { timingSafeEqual, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { z } from 'zod';
import { actionSchema, connectionSchema, scriptSchema } from '../shared/schema';
import { Store, exampleSource, safeName } from './store';
import { Devices } from './devices';
import { Runner } from './runner';
import { Agent } from './agent';
import { AppError, errorMessage } from './errors';
import { parseScript } from './dsl';

const runInput = z.object({ deviceId: z.string().min(1), name: z.string().max(120).optional(), source: z.string().max(100000).optional(), steps: scriptSchema.optional(), params: z.record(z.string(), z.string().max(10000)).optional() });
const mimeTypes: Record<string, string> = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.mp4': 'video/mp4', '.json': 'application/json', '.log': 'text/plain', '.woff2': 'font/woff2', '.woff': 'font/woff' };
async function body(request: IncomingMessage): Promise<unknown> {
  let size = 0; const chunks: Buffer[] = [];
  for await (const chunk of request) { const buffer = Buffer.from(chunk); size += buffer.length; if (size > 1024 * 1024) throw new AppError('Request exceeds 1 MB', 413); chunks.push(buffer); }
  try { return JSON.parse(Buffer.concat(chunks).toString() || '{}') as unknown; } catch { throw new AppError('Invalid JSON body'); }
}
function json(response: ServerResponse, value: unknown, status = 200) { response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); response.end(JSON.stringify(value)); }
function sameToken(candidate: string, expected: string) { const a = Buffer.from(candidate); const b = Buffer.from(expected); return a.length === b.length && timingSafeEqual(a, b); }
function publicUrl(value: string) { const url = new URL(value); url.username = ''; url.password = ''; return url.toString(); }

export async function startServer(options: { directory: string; port?: number; uiDirectory?: string; devOrigin?: string; demo?: boolean; discovery?: boolean; mcpPath?: string }) {
  const store = new Store(options.directory); await store.init();
  const devices = new Devices();
  if (options.demo) { devices.enableDemo(); if (!(await store.tests()).some(test => test.name === 'demo-sign-in.mob')) await store.saveTest('demo-sign-in.mob', exampleSource); }
  const runner = new Runner(devices, store); const agent = new Agent(store, devices, runner);
  let origin = '';
  const server = http.createServer(async (request, response) => {
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    try {
      const host = request.headers.host ?? '';
      if (host !== new URL(origin).host && host !== new URL(origin).host.replace('127.0.0.1', 'localhost')) throw new AppError('Invalid Host header', 403);
      const requestOrigin = request.headers.origin;
      const allowedOrigins = [origin, origin.replace('127.0.0.1', 'localhost'), options.devOrigin].filter(Boolean);
      if (requestOrigin && !allowedOrigins.includes(requestOrigin)) throw new AppError('Origin is not allowed', 403);
      if (requestOrigin) { response.setHeader('Access-Control-Allow-Origin', requestOrigin); response.setHeader('Vary', 'Origin'); }
      if (request.method === 'OPTIONS') { response.writeHead(204, { 'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS' }); response.end(); return; }
      const url = new URL(request.url ?? '/', origin);
      const route = decodeURIComponent(url.pathname);
      const method = request.method ?? 'GET';
      if (route === '/health' && method === 'GET') { json(response, { ok: true, version: '0.1.0' }); return; }
      if (!route.startsWith('/api/')) {
        if (!options.uiDirectory || method !== 'GET') throw new AppError('Not found', 404);
        const requested = route === '/' ? 'index.html' : route.slice(1);
        const file = path.resolve(options.uiDirectory, requested);
        if (!file.startsWith(path.resolve(options.uiDirectory) + path.sep) || !mimeTypes[path.extname(file)]) throw new AppError('Not found', 404);
        const data = await readFile(file);
        response.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
        response.writeHead(200, { 'Content-Type': mimeTypes[path.extname(file)]! }); response.end(data); return;
      }
      const auth = request.headers.authorization ?? '';
      if (!auth.startsWith('Bearer ') || !sameToken(auth.slice(7), store.token)) throw new AppError('A valid Mobdev API token is required', 401);
      if (method === 'GET' && route === '/api/v1/devices') { json(response, { devices: devices.list(), diagnostics: devices.diagnostics }); return; }
      if (method === 'POST' && route === '/api/v1/devices/refresh') { json(response, { devices: await devices.discover(), diagnostics: devices.diagnostics }); return; }
      if (method === 'POST' && route === '/api/v1/demo') { devices.enableDemo(); if (!(await store.tests()).some(test => test.name === 'demo-sign-in.mob')) await store.saveTest('demo-sign-in.mob', exampleSource); json(response, { devices: devices.list() }); return; }
      const deviceRoute = route.match(/^\/api\/v1\/devices\/([^/]+)\/(screenshot|tree|apps|logs|action|baseline|contexts|web)$/);
      if (deviceRoute) {
        const deviceId = deviceRoute[1]!; const endpoint = deviceRoute[2]!; const provider = devices.get(deviceId);
        if (method === 'GET') {
          if (endpoint === 'screenshot') { json(response, await provider.screenshot()); return; }
          if (endpoint === 'tree') { json(response, await provider.tree()); return; }
          if (endpoint === 'apps') { json(response, await provider.apps()); return; }
          if (endpoint === 'logs') { json(response, { text: await provider.logs() }); return; }
          if (endpoint === 'contexts') { if (!provider.contexts) throw new AppError('Web contexts require Appium', 422); json(response, await provider.contexts()); return; }
        }
        if (method === 'POST' && endpoint === 'action') { json(response, await runner.act(deviceId, actionSchema.parse(await body(request)))); return; }
        if (method === 'POST' && endpoint === 'baseline') {
          const input = z.object({ name: z.string().min(1) }).parse(await body(request));
          await devices.exclusive(deviceId, async device => { const screenshot = await device.screenshot(); if (screenshot.mime !== 'image/png') throw new AppError('Baselines require a PNG screenshot'); await store.baseline(input.name, Buffer.from(screenshot.data, 'base64')); });
          json(response, { ok: true }); return;
        }
        if (method === 'POST' && endpoint === 'web') {
          const input = z.object({ context: z.string(), script: z.string().max(100000) }).parse(await body(request));
          json(response, await devices.exclusive(deviceId, async device => { if (!device.web) throw new AppError('Web automation requires Appium', 422); return device.web(input.context, input.script); })); return;
        }
      }
      if (route === '/api/v1/tests' && method === 'GET') { json(response, await store.tests()); return; }
      if (route === '/api/v1/tests' && method === 'PUT') { const input = z.object({ name: z.string(), source: z.string().max(100000) }).parse(await body(request)); parseScript(input.source); json(response, await store.saveTest(input.name, input.source)); return; }
      if (route === '/api/v1/validate' && method === 'POST') { const input = z.object({ source: z.string() }).parse(await body(request)); json(response, { steps: parseScript(input.source) }); return; }
      if (route === '/api/v1/runs' && method === 'GET') { json(response, await runner.list()); return; }
      if (route === '/api/v1/runs' && method === 'POST') { json(response, await runner.start(runInput.parse(await body(request))), 202); return; }
      if (route === '/api/v1/suites' && method === 'POST') {
        const input = z.object({ deviceIds: z.array(z.string()).min(1).max(20), names: z.array(z.string()).min(1).max(50), params: z.record(z.string(), z.string()).optional() }).parse(await body(request));
        if (input.deviceIds.length * input.names.length > 100) throw new AppError('Maximum 100 runs per suite');
        input.deviceIds.forEach(id => devices.get(id));
        const tests = await Promise.all(input.names.map(async name => ({ name, steps: parseScript(await store.readTest(name)) })));
        const runs = [];
        for (const deviceId of [...new Set(input.deviceIds)]) for (const test of tests) runs.push(await runner.start({ deviceId, name: test.name, steps: test.steps, params: input.params }));
        json(response, runs, 202); return;
      }
      const runRoute = route.match(/^\/api\/v1\/runs\/([^/]+)(?:\/(cancel|export))?$/);
      if (runRoute && method === 'GET' && !runRoute[2]) { json(response, await runner.get(runRoute[1]!)); return; }
      if (runRoute && method === 'POST' && runRoute[2] === 'cancel') { runner.cancel(runRoute[1]!); json(response, { ok: true }); return; }
      if (runRoute && method === 'GET' && runRoute[2] === 'export') { json(response, await agent.exportRun(runRoute[1]!)); return; }
      const apiRun = route.match(/^\/api\/v1\/apis\/run\/([^/]+)$/);
      if (apiRun && method === 'POST') { const input = z.object({ deviceId: z.string(), params: z.record(z.string(), z.string()).optional() }).parse(await body(request)); const run = await runner.start({ deviceId: input.deviceId, name: apiRun[1], params: input.params }); const result = await runner.wait(run.id); json(response, { status: result.status, values: result.variables, runId: result.id, error: result.error }, result.status === 'passed' ? 200 : 422); return; }
      const artifactRoute = route.match(/^\/api\/v1\/artifacts\/([^/]+)$/);
      if (artifactRoute && method === 'GET') { const name = safeName(artifactRoute[1]!); const data = await store.readArtifact(name); response.writeHead(200, { 'Content-Type': mimeTypes[path.extname(name)] ?? 'application/octet-stream', 'Content-Disposition': `attachment; filename="${name}"`, 'Content-Security-Policy': "sandbox; default-src 'none'", 'Cache-Control': 'no-store' }); response.end(data); return; }
      if (route === '/api/v1/settings' && method === 'GET') { json(response, { directory: store.directory, mcpPath: options.mcpPath ?? path.resolve('dist/cli/mobdev-mcp.js'), agent: { baseUrl: store.settings.agent.baseUrl, model: store.settings.agent.model, hasKey: !!store.settings.agent.apiKey }, connections: store.settings.connections.map(connection => ({ id: connection.id, name: connection.name, platform: connection.platform, url: publicUrl(connection.url), connected: devices.providers.has(`appium:${connection.id}`) })) }); return; }
      if (route === '/api/v1/settings/agent' && method === 'PUT') {
        const input = z.object({ baseUrl: z.url().refine(value => ['http:', 'https:'].includes(new URL(value).protocol) && !new URL(value).username && !new URL(value).password), model: z.string().max(200), apiKey: z.string().max(4096).optional() }).parse(await body(request));
        await store.saveSettings({ ...store.settings, agent: { ...store.settings.agent, ...input } }); json(response, { ok: true }); return;
      }
      if (route === '/api/v1/connections' && method === 'POST') {
        const connection = { ...connectionSchema.parse(await body(request)), id: randomUUID() };
        // Creating an Appium session is explicit and may take time while WDA starts.
        const device = await devices.connect(connection, connection.id);
        try { await store.saveSettings({ ...store.settings, connections: [...store.settings.connections, connection] }); }
        catch (error) { await devices.disconnect(device.id); throw error; }
        json(response, device, 201); return;
      }
      const connectionRoute = route.match(/^\/api\/v1\/connections\/([^/]+)(?:\/(connect|disconnect))?$/);
      if (connectionRoute) {
        const connection = store.settings.connections.find(item => item.id === connectionRoute[1]);
        if (!connection) throw new AppError('Connection not found', 404);
        if (method === 'POST' && connectionRoute[2] === 'connect') { json(response, await devices.connect(connection, connection.id)); return; }
        if (method === 'POST' && connectionRoute[2] === 'disconnect') { await devices.disconnect(`appium:${connection.id}`); json(response, { ok: true }); return; }
        if (method === 'DELETE' && !connectionRoute[2]) { if (devices.providers.has(`appium:${connection.id}`)) await devices.disconnect(`appium:${connection.id}`); await store.saveSettings({ ...store.settings, connections: store.settings.connections.filter(item => item.id !== connection.id) }); json(response, { ok: true }); return; }
      }
      if (route === '/api/v1/agent/draft' && method === 'POST') { const input = z.object({ deviceId: z.string(), prompt: z.string().min(1).max(10000), source: z.string().max(100000).optional() }).parse(await body(request)); json(response, await agent.draft(input.deviceId, input.prompt, input.source)); return; }
      if (route === '/api/v1/agent/run' && method === 'POST') { const input = z.object({ deviceId: z.string(), prompt: z.string().min(1).max(10000) }).parse(await body(request)); json(response, await agent.explore(input.deviceId, input.prompt), 202); return; }
      throw new AppError('Not found', 404);
    } catch (error) {
      const status = error instanceof AppError ? error.status : error instanceof z.ZodError ? 400 : (error as NodeJS.ErrnoException).code === 'ENOENT' ? 404 : 500;
      if (!response.headersSent) json(response, { error: errorMessage(error) }, status === 499 ? 409 : status);
      else response.end();
    }
  });
  server.requestTimeout = 120000; server.headersTimeout = 15000;
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(options.port ?? 4686, '127.0.0.1', () => { server.removeListener('error', reject); const address = server.address(); if (!address || typeof address === 'string') { reject(new Error('Missing server address')); return; } origin = `http://127.0.0.1:${address.port}`; resolve(); }); });
  const discovery = options.discovery === false ? Promise.resolve() : devices.discover().then(() => {});
  discovery.catch(() => {});
  return { url: origin, token: store.token, store, devices, runner, agent, discovery, close: async () => { await runner.close(); await devices.close(); await new Promise<void>((resolve, reject) => { server.close(error => error ? reject(error) : resolve()); server.closeIdleConnections(); }); } };
}

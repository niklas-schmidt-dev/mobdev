import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { build } from 'esbuild';
import { startServer } from '../src/server/server';

test('MCP initializes over stdio, exposes tools and drives the local service', { timeout: 60000 }, async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'mobdev-mcp-'));
  const service = await startServer({ directory, port: 0, demo: true, discovery: false });
  const entry = path.join(directory, 'mcp.mjs');
  await build({ entryPoints: [path.resolve('src/cli/mcp.ts')], outfile: entry, bundle: true, platform: 'node', format: 'esm', target: 'node22', banner: { js: "import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);" } });
  const transport = new StdioClientTransport({ command: process.execPath, args: [entry], env: { PATH: process.env.PATH ?? '', MOBDEV_HOME: directory, MOBDEV_URL: service.url }, stderr: 'pipe' });
  const client = new Client({ name: 'mobdev-acceptance', version: '1.0.0' });
  t.after(async () => { await client.close(); await service.close(); await rm(directory, { recursive: true, force: true }); });
  let stderr = '';
  transport.stderr?.on('data', chunk => { stderr += String(chunk); });
  try { await client.connect(transport, { timeout: 45000 }); }
  catch (error) { throw new Error(`MCP initialization failed: ${String(error)}\n${stderr}`); }
  const tools = await client.listTools();
  assert.equal(tools.tools.length, 14); assert.ok(tools.tools.some(tool => tool.name === 'execute_script'));
  const resources = await client.readResource({ uri: 'mobdev://reference/scripts' }); assert.match(JSON.stringify(resources), /wait_for/);
  const tree = await client.callTool({ name: 'get_ui_tree', arguments: { deviceId: 'demo:android' } }); assert.match(JSON.stringify(tree), /Sign in/);
  const tapped = await client.callTool({ name: 'device_action', arguments: { deviceId: 'demo:android', command: { action: 'tap', target: 'Sign in' } } }); assert.ok(!tapped.isError);
  const after = await client.callTool({ name: 'get_ui_tree', arguments: { deviceId: 'demo:android' } }); assert.match(JSON.stringify(after), /Email/);
  const failed = await client.callTool({ name: 'device_action', arguments: { deviceId: 'missing', command: { action: 'key', key: 'home' } } }); assert.equal(failed.isError, true);
});

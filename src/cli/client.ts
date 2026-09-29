import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { dataDirectory } from '../shared/paths';
export async function credentials() {
  return { url: process.env.MOBDEV_URL ?? 'http://127.0.0.1:4686', token: process.env.MOBDEV_TOKEN ?? (await readFile(path.join(dataDirectory(), 'token'), 'utf8')).trim() };
}
export async function api<T>(route: string, body?: unknown, method = body === undefined ? 'GET' : 'POST'): Promise<T> {
  const { url, token } = await credentials();
  let response: Response;
  try { response = await fetch(`${url}/api/v1${route}`, { method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(11 * 60 * 1000), redirect: 'error' }); }
  catch (error) { throw new Error(`Cannot reach Mobdev at ${url}. Start the desktop app or daemon. ${error instanceof Error ? error.message : ''}`); }
  if (!response.ok) { const result = await response.json() as { error?: string }; throw new Error(result.error ?? `HTTP ${response.status}`); }
  return await response.json() as T;
}

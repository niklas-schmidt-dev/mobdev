import type { Bootstrap } from '../shared/schema';
declare global { interface Window { mobdev?: { bootstrap(): Promise<Bootstrap> } } }
export class Client {
  constructor(public connection: Bootstrap) {}
  async call<T>(route: string, body?: unknown, method = body === undefined ? 'GET' : 'POST', signal?: AbortSignal): Promise<T> {
    const response = await fetch(`${this.connection.url}/api/v1${route}`, { method, headers: { Authorization: `Bearer ${this.connection.token}`, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body), signal });
    const result: unknown = await response.json();
    if (!response.ok) throw new Error(typeof result === 'object' && result && 'error' in result ? String(result.error) : `Request failed (${response.status})`);
    return result as T;
  }
  async download(name: string) {
    const response = await fetch(`${this.connection.url}/api/v1/artifacts/${encodeURIComponent(name)}`, { headers: { Authorization: `Bearer ${this.connection.token}` } });
    if (!response.ok) throw new Error('Could not download artifact');
    const url = URL.createObjectURL(await response.blob()); const link = document.createElement('a'); link.href = url; link.download = name; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
}
export interface PublicSettings {
  directory: string;
  mcpPath: string;
  agent: { baseUrl: string; model: string; hasKey: boolean };
  connections: Array<{ id: string; name: string; url: string; platform: 'android'|'ios'; connected: boolean }>;
}
export function message(error: unknown) { return error instanceof Error ? error.message : String(error); }

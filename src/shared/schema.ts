import { z } from 'zod';

const text = z.string().min(1).max(4096);
const coordinate = z.number().int().min(0).max(20000);
export const actionSchema = z.discriminatedUnion('action', [
  z.object({ action: z.literal('tap'), target: text.optional(), x: coordinate.optional(), y: coordinate.optional() }),
  z.object({ action: z.literal('type'), target: text.optional(), text: z.string().max(10000) }),
  z.object({ action: z.literal('swipe'), x: coordinate, y: coordinate, toX: coordinate, toY: coordinate, duration: z.number().int().min(50).max(10000).default(400) }),
  z.object({ action: z.literal('key'), key: z.enum(['home', 'back', 'enter']) }),
  z.object({ action: z.literal('launch'), appId: text }),
  z.object({ action: z.literal('stop'), appId: text }),
  z.object({ action: z.literal('install'), path: text }),
  z.object({ action: z.literal('screenshot'), name: text.default('screenshot') }),
  z.object({ action: z.literal('wait'), ms: z.number().int().min(0).max(60000) }),
  z.object({ action: z.literal('wait_for'), target: text, timeout: z.number().int().min(0).max(60000).default(10000) }),
  z.object({ action: z.literal('assert'), target: text }),
  z.object({ action: z.literal('assert_not'), target: text }),
  z.object({ action: z.literal('extract'), target: text, variable: z.string().regex(/^[a-zA-Z_]\w{0,63}$/) }),
  z.object({ action: z.literal('run'), name: text }),
  z.object({ action: z.literal('record_start') }),
  z.object({ action: z.literal('record_stop'), name: text.default('recording') }),
  z.object({ action: z.literal('measure_perf'), appId: text }),
  z.object({ action: z.literal('assert_perf'), metric: z.enum(['memory_mb', 'jank_percent']), operator: z.enum(['<', '<=', '>', '>=']), value: z.number().finite() }),
  z.object({ action: z.literal('assert_baseline'), name: text, threshold: z.number().min(0).max(1).default(0.01) }),
]);
export type Action = z.infer<typeof actionSchema>;
export const scriptSchema = z.array(actionSchema).min(1).max(500);
export type Platform = 'android' | 'ios';
export type Capability = 'screenshot' | 'input' | 'tree' | 'apps' | 'install' | 'logs' | 'record' | 'performance' | 'web';
export interface Device {
  id: string;
  name: string;
  platform: Platform;
  provider: 'adb' | 'simulator' | 'appium' | 'demo';
  kind: 'physical' | 'emulator' | 'simulator' | 'remote' | 'demo';
  status: 'ready' | 'offline' | 'unauthorized' | 'booting';
  version?: string;
  hardwareId?: string;
  recording?: boolean;
  capabilities: Capability[];
}
export interface UIElement { id: string; text: string; label: string; type: string; bounds: { x: number; y: number; width: number; height: number }; enabled: boolean }
export interface Screenshot { data: string; mime: 'image/png' | 'image/svg+xml'; width: number; height: number }
export interface TestCase { name: string; source: string; updatedAt: string }
export interface RunStep { index: number; command: Action; status: 'running' | 'passed' | 'failed'; durationMs: number; output?: unknown; error?: string }
export interface Run { id: string; name: string; deviceId: string; deviceName: string; status: 'queued' | 'running' | 'passed' | 'failed' | 'cancelled'; startedAt: string; finishedAt?: string; steps: RunStep[]; error?: string; artifacts: string[]; variables: Record<string, string>; report?: string; source?: string }
export interface Diagnostic { name: string; available: boolean; detail: string }
export const connectionSchema = z.object({
  name: z.string().min(1).max(80),
  url: z.url().refine(value => ['http:', 'https:'].includes(new URL(value).protocol), 'Use http or https'),
  platform: z.enum(['android', 'ios']),
  capabilities: z.record(z.string(), z.unknown()).default({}),
});
export type ConnectionInput = z.infer<typeof connectionSchema>;
export interface AgentSettings { baseUrl: string; model: string; apiKey?: string }
export interface Settings { agent: AgentSettings; connections: Array<ConnectionInput & { id: string }> }
export interface Bootstrap { url: string; token: string }

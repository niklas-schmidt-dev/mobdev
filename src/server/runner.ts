import { randomUUID } from 'node:crypto';
import { PNG } from 'pngjs';
import pixelmatch from 'pixelmatch';
import type { Action, Run } from '../shared/schema';
import { Devices } from './devices';
import { Store, safeName } from './store';
import { parseScript, expandAction, toScript } from './dsl';
import { AppError, aborted, errorMessage, pause } from './errors';
import { findElement } from './elements';
import type { Provider } from './providers/provider';

interface Context { variables: Record<string, string>; metrics: Record<string, number>; artifacts: string[]; recording: boolean; prefix: string }
export type Planner = (provider: Provider, run: Run, signal: AbortSignal) => Promise<{ steps: Action[]; report?: string }>;
export class Runner {
  active = new Map<string, { run: Run; controller: AbortController; done: Promise<void> }>();
  constructor(public devices: Devices, public store: Store) {}
  private context(prefix: string = randomUUID()): Context { return { variables: {}, metrics: {}, artifacts: [], recording: false, prefix }; }
  async perform(provider: Provider, action: Action, context: Context, signal?: AbortSignal): Promise<unknown> {
    aborted(signal);
    const tapTarget = async (target: string) => { const e = findElement(await provider.tree(signal), target, true); await provider.tap(Math.round(e.bounds.x + e.bounds.width / 2), Math.round(e.bounds.y + e.bounds.height / 2), signal); };
    const capture = async (name: string) => {
      const screenshot = await provider.screenshot(signal);
      const file = `${context.prefix}-${safeName(name)}-${randomUUID().slice(0, 8)}.${screenshot.mime === 'image/png' ? 'png' : 'svg'}`;
      await this.store.artifact(file, Buffer.from(screenshot.data, 'base64')); context.artifacts.push(file);
      return { artifact: file, width: screenshot.width, height: screenshot.height };
    };
    switch (action.action) {
      case 'tap':
        if (action.target) await tapTarget(action.target);
        else if (action.x !== undefined && action.y !== undefined) await provider.tap(action.x, action.y, signal);
        else throw new AppError('tap requires a target or both x and y coordinates');
        break;
      case 'type': if (action.target) await tapTarget(action.target); await provider.type(action.text, signal); break;
      case 'swipe': await provider.swipe(action.x, action.y, action.toX, action.toY, action.duration, signal); break;
      case 'key': await provider.key(action.key, signal); break;
      case 'launch': await provider.launch(action.appId, signal); break;
      case 'stop': await provider.stop(action.appId, signal); break;
      case 'install': await provider.install(action.path, signal); break;
      case 'wait': await pause(action.ms, signal); break;
      case 'wait_for': {
        const deadline = Date.now() + action.timeout;
        while (true) {
          aborted(signal);
          try { return findElement(await provider.tree(signal), action.target); }
          catch (error) { if (!(error instanceof AppError) || error.status !== 404 || Date.now() >= deadline) throw error; }
          await pause(Math.min(350, Math.max(0, deadline - Date.now())), signal);
        }
      }
      case 'assert': return findElement(await provider.tree(signal), action.target);
      case 'assert_not': {
        const elements = await provider.tree(signal);
        try { findElement(elements, action.target); }
        catch (error) { if (error instanceof AppError && error.status === 404) return { absent: true }; throw error; }
        throw new AppError(`Unexpected element is visible: ${action.target}`, 422);
      }
      case 'extract': { const e = findElement(await provider.tree(signal), action.target); context.variables[action.variable] = e.text || e.label; return { [action.variable]: context.variables[action.variable] }; }
      case 'screenshot': return capture(action.name);
      case 'record_start':
        if (!provider.startRecording) throw new AppError('This device does not support recording', 422);
        await provider.startRecording(signal); context.recording = true; break;
      case 'record_stop': {
        if (!provider.stopRecording) throw new AppError('This device does not support recording', 422);
        const data = await provider.stopRecording(signal); context.recording = false;
        const file = `${context.prefix}-${safeName(action.name)}.mp4`;
        await this.store.artifact(file, data); context.artifacts.push(file); return { artifact: file };
      }
      case 'measure_perf':
        if (!provider.metrics) throw new AppError('Performance metrics are available for direct ADB devices', 422);
        context.metrics = await provider.metrics(action.appId, signal); return context.metrics;
      case 'assert_perf': {
        const value = context.metrics[action.metric];
        if (value === undefined) throw new AppError(`No measured value for ${action.metric}. Run measure_perf first.`, 422);
        const passes = { '<': value < action.value, '<=': value <= action.value, '>': value > action.value, '>=': value >= action.value }[action.operator];
        if (!passes) throw new AppError(`${action.metric}: measured ${value.toFixed(2)}, expected ${action.operator} ${action.value}`, 422);
        return { [action.metric]: value };
      }
      case 'assert_baseline': {
        const screenshot = await provider.screenshot(signal);
        if (screenshot.mime !== 'image/png') throw new AppError('Visual baselines require a real PNG screenshot', 422);
        const baseline = PNG.sync.read(await this.store.baseline(action.name));
        const current = PNG.sync.read(Buffer.from(screenshot.data, 'base64'));
        if (baseline.width !== current.width || baseline.height !== current.height) throw new AppError('Baseline dimensions differ from this device', 422);
        const diff = new PNG({ width: current.width, height: current.height });
        const pixels = pixelmatch(baseline.data, current.data, diff.data, current.width, current.height, { threshold: 0.1 });
        const ratio = pixels / (current.width * current.height);
        const file = `${context.prefix}-${safeName(action.name)}-diff.png`;
        await this.store.artifact(file, PNG.sync.write(diff)); context.artifacts.push(file);
        if (ratio > action.threshold) throw new AppError(`Visual difference ${(ratio * 100).toFixed(2)}% exceeds ${(action.threshold * 100).toFixed(2)}%`, 422);
        return { difference: ratio, artifact: file };
      }
      case 'run': throw new AppError('Nested scripts can only be executed inside a test run');
    }
    return { ok: true };
  }
  async act(deviceId: string, action: Action) { return this.devices.exclusive(deviceId, provider => this.perform(provider, action, this.context())); }
  async start(input: { deviceId: string; name?: string; source?: string; steps?: Action[]; params?: Record<string, string> }, planner?: Planner): Promise<Run> {
    const provider = this.devices.get(input.deviceId);
    const actions = planner ? [] : input.steps ?? parseScript(input.source ?? await this.store.readTest(input.name ?? ''));
    const run: Run = { id: randomUUID(), name: input.name ?? 'Untitled run', deviceId: input.deviceId, deviceName: provider.device.name, status: 'queued', source: planner ? undefined : toScript(actions), startedAt: new Date().toISOString(), steps: [], artifacts: [], variables: { ...input.params } };
    await this.store.saveRun(run);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10 * 60 * 1000);
    const done = this.devices.exclusive(input.deviceId, async device => {
      const context = this.context(run.id); context.variables = run.variables; context.artifacts = run.artifacts;
      run.status = 'running'; await this.store.saveRun(run);
      try {
        const execute = async (commands: Action[], ancestors: string[] = []) => {
          for (const unresolved of commands) {
            aborted(controller.signal);
            if (run.steps.length >= 1000) throw new AppError('Expanded script exceeds 1,000 steps');
            const step: Run['steps'][number] = { index: run.steps.length, command: unresolved, status: 'running', durationMs: 0 };
            run.steps.push(step); const start = Date.now();
            try {
              const action = expandAction(unresolved, context.variables);
              if (action.action === 'run') {
                const name = action.name.endsWith('.mob') ? action.name : `${action.name}.mob`;
                if (ancestors.includes(name) || ancestors.length >= 10) throw new AppError(`Recursive include: ${name}`);
                await execute(parseScript(await this.store.readTest(name)), [...ancestors, name]);
              } else step.output = await this.perform(device, action, context, controller.signal);
              step.status = 'passed';
            } catch (error) { step.status = 'failed'; step.error = errorMessage(error); throw error; }
            finally { step.durationMs = Date.now() - start; await this.store.saveRun(run); }
          }
        };
        await execute(actions, input.name ? [input.name.endsWith('.mob') ? input.name : `${input.name}.mob`] : []);
        if (planner) {
          let completed = false;
          for (let iteration = 0; iteration < 30; iteration++) {
            aborted(controller.signal);
            const next = await planner(device, run, controller.signal);
            await execute(next.steps);
            if (next.report) { run.report = next.report; completed = true; break; }
            if (!next.steps.length) throw new AppError('Agent returned no next action or final report');
          }
          if (!completed) throw new AppError('Agent reached its 30-turn limit. Review the run before continuing.');
        }
        run.status = 'passed';
      } catch (error) {
        run.status = controller.signal.aborted ? 'cancelled' : 'failed'; run.error = errorMessage(error);
        if (!controller.signal.aborted) {
          await this.perform(device, { action: 'screenshot', name: 'failure' }, context).catch(() => {});
          try { const logs = await device.logs(); const name = `${run.id}-device.log`; await this.store.artifact(name, Buffer.from(logs)); run.artifacts.push(name); } catch {}
        }
      } finally {
        if (context.recording && device.stopRecording) {
          try { await this.perform(device, { action: 'record_stop', name: 'interrupted-recording' }, context); }
          catch (error) { run.status = 'failed'; run.error = `${run.error ?? ''} Recording finalization failed: ${errorMessage(error)}`.trim(); }
        }
        run.finishedAt = new Date().toISOString(); await this.store.saveRun(run);
      }
    }, controller.signal).catch(async error => { run.status = controller.signal.aborted ? 'cancelled' : 'failed'; run.error = errorMessage(error); run.finishedAt = new Date().toISOString(); await this.store.saveRun(run); }).finally(() => { clearTimeout(timer); this.active.delete(run.id); });
    this.active.set(run.id, { run, controller, done });
    return run;
  }
  async list() { const stored = await this.store.runs(); return stored.map(run => this.active.get(run.id)?.run ?? run); }
  async get(id: string) { const run = this.active.get(id)?.run ?? (await this.store.runs()).find(run => run.id === id); if (!run) throw new AppError('Run not found', 404); return run; }
  async wait(id: string) { await this.active.get(id)?.done; return this.get(id); }
  cancel(id: string) { const task = this.active.get(id); if (!task) throw new AppError('Run is no longer active', 409); task.controller.abort(); }
  async close() { for (const task of this.active.values()) task.controller.abort(); await Promise.allSettled([...this.active.values()].map(task => task.done)); }
}

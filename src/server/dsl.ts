import { actionSchema, type Action } from '../shared/schema';
import { AppError } from './errors';

/** Tokenize before variable expansion, so parameters can never inject commands. */
export function tokenize(line: string): string[] {
  const result: string[] = [];
  let index = 0;
  while (index < line.length) {
    if (/\s/.test(line[index]!)) { index++; continue; }
    if (line[index] === '#') break;
    if (line[index] === '"') {
      const start = index++;
      let closed = false;
      while (index < line.length) {
        if (line[index] === '\\') { index += 2; continue; }
        if (line[index++] === '"') { closed = true; break; }
      }
      if (!closed) throw new AppError('Unterminated quoted string');
      try { result.push(JSON.parse(line.slice(start, index)) as string); } catch { throw new AppError('Invalid string escape; use JSON double-quoted strings'); }
      if (index < line.length && !/[\s#]/.test(line[index]!)) throw new AppError('Expected a space after a quoted string');
    } else {
      const start = index;
      while (index < line.length && !/[\s#]/.test(line[index]!)) index++;
      result.push(line.slice(start, index));
    }
  }
  return result;
}
export function parseScript(source: string): Action[] {
  if (source.length > 100000) throw new AppError('Script is too large');
  const actions: Action[] = [];
  for (const [index, line] of source.split(/\r?\n/).entries()) {
    try {
      const [command, ...args] = tokenize(line);
      if (!command) continue;
      const count = (min: number, max = min) => { if (args.length < min || args.length > max) throw new AppError(`${command} expects ${min === max ? min : `${min}–${max}`} arguments`); };
      let action: unknown;
      switch (command) {
        case 'tap': count(1, 2); action = args.length === 1 ? { action: 'tap', target: args[0] } : { action: 'tap', x: Number(args[0]), y: Number(args[1]) }; break;
        case 'type': count(1, 2); action = { action: 'type', target: args.length === 2 ? args[0] : undefined, text: args.at(-1) }; break;
        case 'swipe': count(4, 5); action = { action: 'swipe', x: Number(args[0]), y: Number(args[1]), toX: Number(args[2]), toY: Number(args[3]), duration: args[4] === undefined ? 400 : Number(args[4]) }; break;
        case 'key': count(1); action = { action: command, key: args[0] }; break;
        case 'launch': case 'stop': count(1); action = { action: command, appId: args[0] }; break;
        case 'install': count(1); action = { action: command, path: args[0] }; break;
        case 'screenshot': case 'record_stop': count(0, 1); action = { action: command, name: args[0] }; break;
        case 'wait': count(1); action = { action: command, ms: Number(args[0]) }; break;
        case 'wait_for': count(1, 2); action = { action: command, target: args[0], timeout: args[1] === undefined ? 10000 : Number(args[1]) }; break;
        case 'assert': case 'assert_not': count(1); action = { action: command, target: args[0] }; break;
        case 'extract': count(2); action = { action: command, variable: args[0], target: args[1] }; break;
        case 'run': count(1); action = { action: command, name: args[0] }; break;
        case 'record_start': count(0); action = { action: command }; break;
        case 'measure_perf': count(1); action = { action: command, appId: args[0] }; break;
        case 'assert_perf': count(3); action = { action: command, metric: args[0], operator: args[1], value: Number(args[2]) }; break;
        case 'assert_baseline': count(1, 2); action = { action: command, name: args[0], threshold: args[1] === undefined ? 0.01 : Number(args[1]) }; break;
        default: throw new AppError(`Unknown command: ${command}`);
      }
      actions.push(actionSchema.parse(action));
      if (actions.length > 500) throw new AppError('Maximum 500 steps per script');
    } catch (error) { throw new AppError(`Line ${index + 1}: ${error instanceof Error ? error.message : String(error)}`); }
  }
  if (!actions.length) throw new AppError('The script has no commands');
  return actions;
}
export function expandAction(action: Action, variables: Record<string, string>): Action {
  return actionSchema.parse(Object.fromEntries(Object.entries(action).map(([key, value]) => [key, typeof value === 'string' && key !== 'action' ? value.replace(/\$\{([a-zA-Z_]\w*)\}/g, (_, name: string) => {
    if (!Object.hasOwn(variables, name)) throw new AppError(`Missing parameter: ${name}`);
    return variables[name]!;
  }) : value])));
}
export function toScript(actions: Action[]): string {
  const q = (value: string) => JSON.stringify(value);
  return actions.map(a => {
    switch (a.action) {
      case 'tap': return a.target ? `tap ${q(a.target)}` : `tap ${a.x} ${a.y}`;
      case 'type': return `type ${a.target ? q(a.target) + ' ' : ''}${q(a.text)}`;
      case 'swipe': return `swipe ${a.x} ${a.y} ${a.toX} ${a.toY} ${a.duration}`;
      case 'key': return `key ${a.key}`;
      case 'launch': case 'stop': case 'measure_perf': return `${a.action} ${q(a.appId)}`;
      case 'install': return `install ${q(a.path)}`;
      case 'wait': return `wait ${a.ms}`;
      case 'wait_for': return `wait_for ${q(a.target)} ${a.timeout}`;
      case 'assert': case 'assert_not': return `${a.action} ${q(a.target)}`;
      case 'extract': return `extract ${a.variable} ${q(a.target)}`;
      case 'assert_perf': return `assert_perf ${a.metric} ${a.operator} ${a.value}`;
      case 'assert_baseline': return `assert_baseline ${q(a.name)} ${a.threshold}`;
      case 'record_start': return 'record_start';
      case 'screenshot': case 'record_stop': case 'run': return `${a.action} ${q(a.name)}`;
    }
  }).join('\n') + '\n';
}

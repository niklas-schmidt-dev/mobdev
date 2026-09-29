import { execFile } from 'node:child_process';
import { access } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { AppError } from './errors';

export async function command(executable: string, args: string[], options: { timeout?: number; signal?: AbortSignal } = {}): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    execFile(executable, args, { encoding: 'buffer', maxBuffer: 32 * 1024 * 1024, timeout: options.timeout ?? 20000, signal: options.signal, windowsHide: true }, (error, stdout, stderr) => {
      if (error) reject(new AppError(`${path.basename(executable)}: ${stderr.toString().trim() || error.message}`, 502));
      else resolve(stdout);
    });
  });
}
export async function adbPath(): Promise<string> {
  const file = process.platform === 'win32' ? 'adb.exe' : 'adb';
  const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT;
  const candidates = [process.env.MOBDEV_ADB, sdk && path.join(sdk, 'platform-tools', file), path.join(homedir(), 'Library/Android/sdk/platform-tools', file), path.join(homedir(), 'Android/Sdk/platform-tools', file), process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Android/Sdk/platform-tools', file)];
  for (const candidate of candidates) { if (candidate) { try { await access(candidate); return candidate; } catch {} } }
  return file;
}
// adb shell concatenates its arguments. Quote every argument again for the device shell.
export function shellQuote(value: string) { return `'${value.replaceAll("'", "'\\''")}'`; }

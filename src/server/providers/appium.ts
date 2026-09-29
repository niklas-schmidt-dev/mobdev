import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import type { ConnectionInput, Device, Screenshot } from '../../shared/schema';
import { AppError } from '../errors';
import { parseElements } from '../elements';
import type { Provider } from './provider';

export class AppiumProvider implements Provider {
  private sessionId = '';
  constructor(public device: Device, private connection: ConnectionInput) {}
  private async request<T>(method: string, route: string, body?: unknown, signal?: AbortSignal): Promise<T> {
    const url = new URL(`${this.connection.url.replace(/\/$/, '')}${route}`);
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (url.username || url.password) {
      headers.Authorization = `Basic ${Buffer.from(`${decodeURIComponent(url.username)}:${decodeURIComponent(url.password)}`).toString('base64')}`;
      url.username = ''; url.password = '';
    }
    const timeout = AbortSignal.timeout(route === '/session' ? 180000 : 60000);
    const response = await fetch(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: signal ? AbortSignal.any([signal, timeout]) : timeout, redirect: 'error' });
    const result = await response.json() as { value?: T & { error?: string; message?: string }; sessionId?: string };
    if (!response.ok || result.value?.error) throw new AppError(result.value?.message ?? `Appium returned HTTP ${response.status}`, 502);
    return result.value as T;
  }
  private session<T>(method: string, route: string, body?: unknown, signal?: AbortSignal) {
    if (!this.sessionId) throw new AppError('Appium session is not connected', 409);
    return this.request<T>(method, `/session/${encodeURIComponent(this.sessionId)}${route}`, body, signal);
  }
  private execute<T>(script: string, args: Record<string, unknown>, signal?: AbortSignal) { return this.session<T>('POST', '/execute/sync', { script, args: [args] }, signal); }
  async connect() {
    const value = await this.request<{ sessionId: string }>('POST', '/session', { capabilities: { alwaysMatch: { platformName: this.device.platform === 'ios' ? 'iOS' : 'Android', 'appium:automationName': this.device.platform === 'ios' ? 'XCUITest' : 'UiAutomator2', 'appium:noReset': true, 'appium:newCommandTimeout': 0, ...this.connection.capabilities }, firstMatch: [{}] } });
    if (!value.sessionId) throw new AppError('Appium did not return a W3C session ID', 502);
    this.sessionId = value.sessionId;
  }
  async screenshot(signal?: AbortSignal): Promise<Screenshot> {
    const data = await this.session<string>('GET', '/screenshot', undefined, signal);
    const rect = await this.session<{ width: number; height: number }>('GET', '/window/rect', undefined, signal);
    return { data, mime: 'image/png', width: rect.width, height: rect.height };
  }
  async tree(signal?: AbortSignal) { return parseElements(await this.session<string>('GET', '/source', undefined, signal)); }
  private async pointer(actions: unknown[], signal?: AbortSignal) {
    try { await this.session('POST', '/actions', { actions: [{ type: 'pointer', id: 'finger', parameters: { pointerType: 'touch' }, actions }] }, signal); }
    finally { await this.session('DELETE', '/actions').catch(() => {}); }
  }
  async tap(x: number, y: number, signal?: AbortSignal) { await this.pointer([{ type: 'pointerMove', duration: 0, x, y, origin: 'viewport' }, { type: 'pointerDown', button: 0 }, { type: 'pause', duration: 80 }, { type: 'pointerUp', button: 0 }], signal); }
  async swipe(x: number, y: number, toX: number, toY: number, duration: number, signal?: AbortSignal) { await this.pointer([{ type: 'pointerMove', duration: 0, x, y, origin: 'viewport' }, { type: 'pointerDown', button: 0 }, { type: 'pause', duration: 100 }, { type: 'pointerMove', duration, x: toX, y: toY, origin: 'viewport' }, { type: 'pointerUp', button: 0 }], signal); }
  async type(text: string, signal?: AbortSignal) {
    try { await this.session('POST', '/actions', { actions: [{ type: 'key', id: 'keyboard', actions: Array.from(text).flatMap(value => [{ type: 'keyDown', value }, { type: 'keyUp', value }]) }] }, signal); }
    finally { await this.session('DELETE', '/actions').catch(() => {}); }
  }
  async key(key: 'home'|'back'|'enter', signal?: AbortSignal) {
    if (this.device.platform === 'android') { await this.session('POST', '/appium/device/press_keycode', { keycode: { home: 3, back: 4, enter: 66 }[key] }, signal); return; }
    if (key === 'home') await this.execute('mobile: pressButton', { name: 'home' }, signal);
    else if (key === 'enter') await this.type('\uE007', signal);
    else throw new AppError('iOS has no system Back key. Tap the app’s back button.');
  }
  async launch(appId: string, signal?: AbortSignal) { await this.session('POST', '/appium/device/activate_app', { appId }, signal); }
  async stop(appId: string, signal?: AbortSignal) { await this.session('POST', '/appium/device/terminate_app', { appId }, signal); }
  async install(file: string, signal?: AbortSignal) {
    if (!path.isAbsolute(file) || !/\.(apk|ipa|zip)$/i.test(file)) throw new AppError('Provide an absolute .apk, .ipa or zipped .app path');
    if ((await stat(file)).size > 200 * 1024 * 1024) throw new AppError('App exceeds the 200 MB upload limit');
    await this.session('POST', '/appium/device/install_app', { app: (await readFile(file)).toString('base64') }, signal);
  }
  async apps(): Promise<Array<{ id: string; name: string }>> { throw new AppError('App listing is not standardized across Appium drivers. Use an app ID to launch.', 422); }
  async logs(signal?: AbortSignal) {
    const entries = await this.session<Array<{ timestamp: number; level: string; message: string }>>('POST', '/se/log', { type: this.device.platform === 'ios' ? 'syslog' : 'logcat' }, signal);
    return entries.slice(-200).map(entry => `${entry.level} ${entry.message}`).join('\n');
  }
  async startRecording(signal?: AbortSignal) { if (this.device.recording) throw new AppError('Recording already running', 409); await this.session('POST', '/appium/start_recording_screen', { options: { timeLimit: '180' } }, signal); this.device.recording = true; }
  async stopRecording(signal?: AbortSignal) {
    const data = await this.session<string>('POST', '/appium/stop_recording_screen', { options: {} }, signal);
    this.device.recording = false;
    if (!data) throw new AppError('The Appium driver returned an empty recording', 502);
    return Buffer.from(data, 'base64');
  }
  async contexts() { return this.session<string[]>('GET', '/contexts'); }
  async web(context: string, script: string) {
    if (context === 'NATIVE_APP' || !(await this.contexts()).includes(context)) throw new AppError('Select an available WEBVIEW context');
    const previous = await this.session<string>('GET', '/context');
    try { await this.session('POST', '/context', { name: context }); return await this.session('POST', '/execute/sync', { script, args: [] }); }
    finally { await this.session('POST', '/context', { name: previous }); }
  }
  async close() { if (this.sessionId) { await this.session('DELETE', ''); this.sessionId = ''; } }
}

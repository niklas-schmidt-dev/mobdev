import type { Device, Screenshot, UIElement } from '../../shared/schema';
import { AppError } from '../errors';
import type { Provider } from './provider';

const escape = (text: string) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
/** Explicit opt-in fixture. Never returned as real hardware. Also powers offline acceptance tests. */
export class DemoProvider implements Provider {
  device: Device = { id: 'demo:android', name: 'Demo phone', platform: 'android', provider: 'demo', kind: 'demo', status: 'ready', version: 'Virtual fixture', capabilities: ['screenshot', 'input', 'tree', 'apps', 'logs'] };
  private screen: 'welcome' | 'login' | 'home' = 'welcome';
  private email = '';
  private history: string[] = [];
  async tree(): Promise<UIElement[]> {
    const element = (id: string, text: string, y: number, type = 'Button'): UIElement => ({ id, text, label: text, type, bounds: { x: 28, y, width: 334, height: 52 }, enabled: true });
    if (this.screen === 'welcome') return [element('welcome-title', 'A little more outside.', 170, 'Text'), element('sign-in', 'Sign in', 590)];
    if (this.screen === 'login') return [element('email', this.email || 'Email', 270, 'EditText'), element('continue', 'Continue', 348), element('back', 'Back', 420)];
    return [element('welcome', `Welcome${this.email ? ', ' + this.email.split('@')[0] : ''}`, 155, 'Text'), element('explore', 'Explore trails', 560), element('sign-out', 'Sign out', 625)];
  }
  async screenshot(): Promise<Screenshot> {
    const elements = await this.tree();
    const title = this.screen === 'welcome' ? 'Make room\nfor the wild.' : this.screen === 'login' ? 'Your next chapter\nstarts here.' : 'Good to have\nyou outside.';
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="390" height="844" viewBox="0 0 390 844"><rect width="390" height="844" fill="#f2f0e8"/><text x="28" y="36" font-family="sans-serif" font-size="14" fill="#29382d">9:41</text><text x="312" y="36" font-family="sans-serif" font-size="12" fill="#29382d">● ▰</text><text x="28" y="101" font-family="sans-serif" font-size="15" font-weight="700" letter-spacing="4" fill="#3c5140">FERN /</text>${title.split('\n').map((line,i) => `<text x="28" y="${157+i*44}" font-family="Georgia,serif" font-size="38" fill="#29382d">${line}</text>`).join('')}${this.screen === 'welcome' ? '<circle cx="195" cy="395" r="128" fill="#d8deca"/><path d="M65 476L162 303L217 402L264 346L337 476Z" fill="#a6b49c"/><path d="M65 476L167 356L224 476Z" fill="#526e54"/><path d="M169 303L195 351L154 333Z" fill="#fcfcf4"/><text x="85" y="557" font-family="sans-serif" font-size="13" fill="#647365">Small adventures. A bigger life.</text>' : ''}${elements.filter(e => e.type !== 'Text').map(e => `<rect x="${e.bounds.x}" y="${e.bounds.y}" width="334" height="52" rx="8" fill="${e.type === 'EditText' ? '#fff' : '#304c39'}"/><text x="${e.type === 'EditText' ? 44 : 195}" y="${e.bounds.y+32}" text-anchor="${e.type === 'EditText' ? 'start' : 'middle'}" font-family="sans-serif" font-size="15" fill="${e.type === 'EditText' ? '#485649' : '#fff'}">${escape(e.text)}</text>`).join('')}${this.screen === 'home' ? `<text x="28" y="270" font-family="sans-serif" font-size="18" fill="#3c5140">${escape(elements[0]!.text)}</text><rect x="28" y="310" width="334" height="210" rx="12" fill="#d8deca"/><path d="M50 490L152 349L203 426L267 375L344 490Z" fill="#758b6b"/>` : ''}<text x="195" y="765" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#7d887c">MOBDEV DEMO · NO PHYSICAL DEVICE</text><rect x="135" y="818" width="120" height="5" rx="3" fill="#344839"/></svg>`;
    return { data: Buffer.from(svg).toString('base64'), mime: 'image/svg+xml', width: 390, height: 844 };
  }
  async tap(x: number, y: number) {
    const hit = (await this.tree()).find(e => x >= e.bounds.x && x <= e.bounds.x + e.bounds.width && y >= e.bounds.y && y <= e.bounds.y + e.bounds.height);
    this.history.push(`tap ${hit?.id ?? `${x},${y}`}`);
    if (hit?.id === 'sign-in') this.screen = 'login';
    if (hit?.id === 'continue') { if (!this.email) throw new AppError('Enter an email address first'); this.screen = 'home'; }
    if (hit?.id === 'back' || hit?.id === 'sign-out') { this.screen = 'welcome'; this.email = ''; }
  }
  async type(text: string) { if (this.screen !== 'login') throw new AppError('Open Sign in before typing'); this.email += text; this.history.push('type [redacted]'); }
  async swipe() { this.history.push('swipe'); }
  async key() { this.screen = 'welcome'; this.email = ''; }
  async launch() { this.screen = 'welcome'; this.email = ''; }
  async stop() { this.screen = 'welcome'; }
  async install(): Promise<never> { throw new AppError('The demo does not support app installation'); }
  async apps() { return [{ id: 'dev.mobdev.fern', name: 'Fern · Demo app' }]; }
  async logs() { return this.history.map(line => `DEMO ${line}`).join('\n') || 'DEMO Ready. This is a virtual test fixture.'; }
}

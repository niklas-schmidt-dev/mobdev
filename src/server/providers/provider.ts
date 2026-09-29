import type { Device, Screenshot, UIElement } from '../../shared/schema';
export interface Provider {
  device: Device;
  screenshot(signal?: AbortSignal): Promise<Screenshot>;
  tree(signal?: AbortSignal): Promise<UIElement[]>;
  tap(x: number, y: number, signal?: AbortSignal): Promise<void>;
  type(text: string, signal?: AbortSignal): Promise<void>;
  swipe(x: number, y: number, toX: number, toY: number, duration: number, signal?: AbortSignal): Promise<void>;
  key(key: 'home' | 'back' | 'enter', signal?: AbortSignal): Promise<void>;
  launch(appId: string, signal?: AbortSignal): Promise<void>;
  stop(appId: string, signal?: AbortSignal): Promise<void>;
  install(file: string, signal?: AbortSignal): Promise<void>;
  apps(signal?: AbortSignal): Promise<Array<{ id: string; name: string }>>;
  logs(signal?: AbortSignal): Promise<string>;
  startRecording?(signal?: AbortSignal): Promise<void>;
  stopRecording?(signal?: AbortSignal): Promise<Buffer>;
  metrics?(appId: string, signal?: AbortSignal): Promise<Record<string, number>>;
  contexts?(): Promise<string[]>;
  web?(context: string, script: string): Promise<unknown>;
  close?(): Promise<void>;
}

import path from 'node:path';
import { homedir } from 'node:os';
export function dataDirectory() {
  if (process.env.MOBDEV_HOME) return path.resolve(process.env.MOBDEV_HOME);
  if (process.platform === 'darwin') return path.join(homedir(), 'Library', 'Application Support', 'Mobdev');
  if (process.platform === 'win32') return path.join(process.env.APPDATA ?? path.join(homedir(), 'AppData', 'Roaming'), 'Mobdev');
  return path.join(process.env.XDG_CONFIG_HOME ?? path.join(homedir(), '.config'), 'Mobdev');
}

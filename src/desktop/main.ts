import { app, BrowserWindow, ipcMain } from 'electron';
import path from 'node:path';
import { startServer } from '../server/server';
import { dataDirectory } from '../shared/paths';

app.setName('Mobdev');
if (!app.requestSingleInstanceLock()) { app.quit(); }
else {
  let window: BrowserWindow | undefined;
  let server: Awaited<ReturnType<typeof startServer>> | undefined;
  let quitting = false;
  const openWindow = async () => {
    if (window) { window.show(); window.focus(); return; }
    window = new BrowserWindow({ width: 1440, height: 960, minWidth: 940, minHeight: 680, title: 'Mobdev', backgroundColor: '#101413', ...(process.platform === 'darwin' ? { titleBarStyle: 'hiddenInset' as const, trafficLightPosition: { x: 18, y: 20 } } : {}), autoHideMenuBar: true, webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true } });
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    window.webContents.on('will-navigate', (event, url) => { if (url !== (process.env.MOBDEV_UI_URL ?? server!.url) + '/') event.preventDefault(); });
    window.on('closed', () => { window = undefined; });
    await window.loadURL(process.env.MOBDEV_UI_URL ?? server!.url);
  };
  app.on('second-instance', () => { if (server) void openWindow(); });
  app.whenReady().then(async () => {
    server = await startServer({ directory: dataDirectory(), uiDirectory: path.join(__dirname, '../ui'), demo: process.env.MOBDEV_DEMO === '1', discovery: process.env.MOBDEV_NO_DISCOVERY !== '1', mcpPath: app.isPackaged ? path.join(process.resourcesPath, 'cli/mobdev-mcp.js') : path.join(__dirname, '../cli/mobdev-mcp.js'), devOrigin: process.env.MOBDEV_UI_URL });
    ipcMain.handle('mobdev:bootstrap', event => {
      if (!window || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame) throw new Error('Unknown renderer');
      return { url: server!.url, token: server!.token };
    });
    await openWindow();
    app.on('activate', () => { void openWindow(); });
  }).catch(async error => { const { dialog } = await import('electron'); dialog.showErrorBox('Mobdev could not start', error instanceof Error ? error.message : String(error)); app.quit(); });
  app.on('window-all-closed', () => app.quit());
  app.on('before-quit', event => {
    if (!quitting && server) { event.preventDefault(); quitting = true; void server.close().finally(() => app.quit()); }
  });
}

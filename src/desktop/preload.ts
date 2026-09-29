import { contextBridge, ipcRenderer } from 'electron';
contextBridge.exposeInMainWorld('mobdev', { bootstrap: () => ipcRenderer.invoke('mobdev:bootstrap') });

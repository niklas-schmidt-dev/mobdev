import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  root: 'src/ui',
  base: './',
  server: { port: 5173, strictPort: true },
  build: { outDir: '../../dist/ui', emptyOutDir: true },
});

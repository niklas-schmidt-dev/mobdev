import { build } from 'esbuild';
import { mkdir, chmod } from 'node:fs/promises';

export async function buildNode() {
  await mkdir('dist', { recursive: true });
  await build({
    entryPoints: ['src/desktop/main.ts', 'src/desktop/preload.ts'],
    outdir: 'dist/desktop', bundle: true, platform: 'node', format: 'cjs',
    outExtension: { '.js': '.cjs' }, external: ['electron'], target: 'node22', sourcemap: true,
  });
  await build({
    entryPoints: { mobdev: 'src/cli/main.ts', 'mobdev-mcp': 'src/cli/mcp.ts' },
    outdir: 'dist/cli', bundle: true, platform: 'node', format: 'esm', target: 'node22',
    banner: { js: "#!/usr/bin/env node\nimport { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);" },
  });
  await chmod('dist/cli/mobdev.js', 0o755);
  await chmod('dist/cli/mobdev-mcp.js', 0o755);
}

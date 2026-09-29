import { build as viteBuild } from 'vite';
import { buildNode } from './build-node.mjs';

await viteBuild();
await buildNode();

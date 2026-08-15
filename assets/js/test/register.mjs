// Registers the resolve hook that lets Node's ESM loader handle the
// extensionless relative imports used across assets/js (esbuild resolves
// them at bundle time; plain Node needs the explicit .js extension).
import { register } from "node:module";

register("./resolve_hooks.mjs", import.meta.url);

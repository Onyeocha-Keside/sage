import { build } from "esbuild";
import { spawnSync } from "node:child_process";
await build({ entryPoints: ["tests/entry.ts"], bundle: true, platform: "node", format: "esm", outfile: ".wrangler/tests/entry.mjs" });
const result = spawnSync(process.execPath, ["--test", "tests/worker.test.mjs"], { stdio: "inherit" });
process.exitCode = result.status ?? 1;

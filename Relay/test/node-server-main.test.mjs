import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, symlinkSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const src = join(dirname(fileURLToPath(import.meta.url)), "..", "src");

function start(script, port) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script], { env: { ...process.env, PORT: String(port), HOST: "127.0.0.1" } });
    let out = "";
    const timer = setTimeout(() => { child.kill(); reject(new Error(`relay did not start via ${script}; output: ${out}`)); }, 4000);
    child.stdout.on("data", (d) => { out += d; if (out.includes("listening")) { clearTimeout(timer); child.kill(); resolve(out); } });
    child.on("exit", (code) => { if (!out.includes("listening")) { clearTimeout(timer); reject(new Error(`relay exited (${code}) without starting via ${script}`)); } });
  });
}

test("the relay starts when launched through a symlinked folder", async () => {
  const dir = mkdtempSync(join(tmpdir(), "kiln relay "));   // a space in the path too
  const link = join(dir, "linked-src");
  symlinkSync(src, link);
  assert.match(await start(join(link, "node-server.mjs"), 20000 + Math.floor(Math.random() * 20000)), /listening/);
});

test("the relay starts when launched by its plain path", async () => {
  assert.match(await start(join(src, "node-server.mjs"), 20000 + Math.floor(Math.random() * 20000)), /listening/);
});

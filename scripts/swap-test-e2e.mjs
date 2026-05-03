#!/usr/bin/env node
import fs from "node:fs";
import { spawn } from "node:child_process";

const env = { ...process.env };
const fresh = env.FRESH === "1" || env.FRESH === "true";

if (!fresh) {
  try {
    const state = JSON.parse(
      fs.readFileSync(env.E2E_STATE || "swap-wallet-e2e-state.json", "utf8"),
    );
    if (!env.RESERVATION_ID && state.reservationId) {
      env.RESERVATION_ID = state.reservationId;
    }
    if (!env.AR_TX_ID && state.arTxId) {
      env.AR_TX_ID = state.arTxId;
    }
    if (!env.AO_MESSAGE_ID && state.aoMessageId) {
      env.AO_MESSAGE_ID = state.aoMessageId;
    }
  } catch {
  }
}

const libDir = "_build/default/lib";
const ebinPaths = fs
  .readdirSync(libDir, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => `${libDir}/${entry.name}/ebin`)
  .filter((path) => fs.existsSync(path));

const child = spawn("erl", [
  "-noshell",
  "-pa",
  ...ebinPaths,
  "-eval",
  'file:script("scripts/swap-test-e2e.erl").',
], {
  env,
  stdio: "inherit",
});

child.on("exit", (status, signal) => {
  if (signal) process.kill(process.pid, signal);
  process.exit(status ?? 1);
});

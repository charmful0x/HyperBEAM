#!/usr/bin/env node
import fs from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const Arweave = require("arweave");

function needEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing env ${name}`);
  return value;
}

function gatewayConfig(rawUrl) {
  const url = new URL(rawUrl);
  return {
    host: url.hostname,
    port: url.port ? Number(url.port) : url.protocol === "https:" ? 443 : 80,
    protocol: url.protocol.replace(":", ""),
    timeout: Number(process.env.HTTP_TIMEOUT || "30000"),
    logging: false,
  };
}

const walletPath = process.env.WALLET || "darwin.json";
const gateway = process.env.GATEWAY || "https://arweave.net";
const target = needEnv("AR_RECIPIENT");
const quantity = needEnv("AR_QUANTITY");
const reservationId = needEnv("RESERVATION_ID");
const swapDevice = needEnv("SWAP_DEVICE");
const outPath = process.env.OUT || "swap-last-ar.json";
const dryRun = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";

if (!/^\d+$/.test(quantity) || BigInt(quantity) <= 0n) {
  throw new Error(`AR_QUANTITY must be a positive winston amount, got ${quantity}`);
}

const jwk = JSON.parse(fs.readFileSync(walletPath, "utf8"));
const arweave = Arweave.init(gatewayConfig(gateway));

console.error(`Creating AR transfer with arweave-js`);
console.error(`Gateway: ${gateway}`);
console.error(`Wallet: ${walletPath}`);
console.error(`Target: ${target}`);
console.error(`Quantity: ${quantity}`);
console.error(`Reservation: ${reservationId}`);

const tx = await arweave.createTransaction(
  {
    target,
    quantity,
    data: "",
  },
  jwk,
);
tx.addTag("swap-device", swapDevice);
tx.addTag("swap-reservation", reservationId);

await arweave.transactions.sign(tx, jwk);
const valid = await arweave.transactions.verify(tx);
if (!valid) {
  throw new Error(`arweave-js produced a transaction that failed local verification`);
}

let post = { status: "dry-run", statusText: "dry-run", data: "" };
if (!dryRun) {
  console.error(`Posting AR tx: ${tx.id}`);
  post = await arweave.transactions.post(tx);
  if (post.status < 200 || post.status >= 300) {
    throw new Error(
      `Arweave post failed (${post.status} ${post.statusText}): ${post.data}`,
    );
  }
}

const result = {
  id: tx.id,
  target,
  quantity,
  reward: tx.reward,
  last_tx: tx.last_tx,
  reservation: reservationId,
  status: post.status,
  statusText: post.statusText,
  response: post.data,
};
fs.writeFileSync(outPath, `${JSON.stringify(result, null, 2)}\n`);
console.log(JSON.stringify(result));

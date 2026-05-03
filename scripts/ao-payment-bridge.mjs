#!/usr/bin/env node
import process from "node:process";

const defaults = {
  token: "0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc",
  node: "http://localhost:8734",
  stateUrl: "https://state.forward.computer",
  quantity: "1",
  sender: "wInbfl1hI4QRfujQrM2As3coOHULK-ooNSpHzgZeXsw",
  lookback: "5000",
  batch: "100",
  timeout: "30000",
};

function usage() {
  console.error(
    [
      "Usage:",
      "  node scripts/ao-payment-bridge.mjs --message-id <id> [options]",
      "",
      "Options:",
      `  --token <id>              AO token process (default ${defaults.token})`,
      "  --ledger <addr>           expected AO transfer recipient",
      `  --node <url>              HyperBEAM node URL (default ${defaults.node})`,
      `  --state-url <url>         AO state endpoint (default ${defaults.stateUrl})`,
      `  --quantity <raw-units>    AO raw units transferred (default ${defaults.quantity})`,
      `  --sender <addr>           AO transfer sender (default ${defaults.sender})`,
      "  --slot <n>                AO schedule slot; auto-found when omitted",
      `  --lookback <n>            slots to scan backwards (default ${defaults.lookback})`,
      `  --batch <n>               schedule range size per request (default ${defaults.batch})`,
      `  --timeout <ms>            HTTP timeout (default ${defaults.timeout})`,
      "  --recipient <addr>        expected X-HB-Recipient tag",
      "  --verify-only             verify without importing",
      "",
      "This helper calls the local HyperBEAM ~ao-payment@1.0 device, which",
      "verifies against the configured mainnet state endpoint.",
    ].join("\n"),
  );
}

function parseArgs(argv) {
  const args = { ...defaults, verifyOnly: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--verify-only") {
      args.verifyOnly = true;
    } else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else if (arg.startsWith("--")) {
      const key = arg.slice(2).replaceAll("-", "_");
      const value = argv[i + 1];
      if (!value || value.startsWith("--")) {
        throw new Error(`Missing value for ${arg}`);
      }
      args[key] = value;
      i += 1;
    } else {
      throw new Error(`Unexpected argument: ${arg}`);
    }
  }
  args.messageId = args.message_id;
  args.stateUrl = args.state_url || args.stateUrl;
  if (!args.messageId) {
    throw new Error("--message-id is required");
  }
  if (!/^\d+$/.test(args.quantity) || BigInt(args.quantity) <= 0n) {
    throw new Error("--quantity must be a positive integer raw unit amount");
  }
  return args;
}

async function fetchWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

function tagValue(tags, name) {
  if (!Array.isArray(tags)) return undefined;
  const found = tags.find((tag) => tag?.name === name || tag?.Name === name);
  return found?.value ?? found?.Value;
}

function parseSlot(value) {
  if (typeof value === "number") return value;
  if (typeof value === "string" && /^\d+$/.test(value.trim())) {
    return Number(value.trim());
  }
  if (value && typeof value === "object") {
    for (const key of ["slot", "Slot", "current", "Current", "body"]) {
      const parsed = parseSlot(value[key]);
      if (Number.isInteger(parsed)) return parsed;
    }
  }
  return undefined;
}

async function fetchAny(url, args) {
  const res = await fetchWithTimeout(
    url,
    { headers: { accept: "application/json" } },
    Number(args.timeout),
  );
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`${url} failed (${res.status}): ${text}`);
  }
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function latestSlot(args) {
  const state = args.stateUrl.replace(/\/$/, "");
  const paths = ["slot/current", "slot"];
  for (const path of paths) {
    const url = `${state}/${args.token}~process@1.0/${path}`;
    try {
      const slot = parseSlot(await fetchAny(url, args));
      if (Number.isInteger(slot)) return slot;
    } catch (err) {
      if (path === paths.at(-1)) throw err;
    }
  }
  throw new Error(`Could not read latest AO slot from ${state}`);
}

function slotFromEdge(edge) {
  const node = edge?.node ?? {};
  const assignment = node.assignment ?? node.Assignment ?? {};
  const nonce = tagValue(assignment.Tags ?? assignment.tags, "Nonce");
  return parseSlot(
    nonce ??
      assignment.slot ??
      assignment.Slot ??
      node.slot ??
      node.Slot ??
      edge.slot ??
      edge.Slot,
  );
}

function findMessageSlot(schedule, args) {
  const edges = schedule?.edges ?? schedule?.Edges ?? [];
  for (const edge of edges) {
    const node = edge?.node ?? {};
    const message = node.message ?? node.Message ?? {};
    const id = message.Id ?? message.id;
    if (id !== args.messageId) continue;

    const tags = message.Tags ?? message.tags ?? [];
    const matches =
      tagValue(tags, "Action") === "Transfer" &&
      tagValue(tags, "Recipient") === args.ledger &&
      String(tagValue(tags, "Quantity")) === String(args.quantity);
    if (!matches) continue;

    const slot = slotFromEdge(edge);
    if (Number.isInteger(slot)) return slot;
  }
  return undefined;
}

async function findSlot(args) {
  const to = args.to ? Number(args.to) : await latestSlot(args);
  const lookback = Number(args.lookback);
  const batch = Number(args.batch);
  const from = args.from ? Number(args.from) : Math.max(0, to - lookback);
  const state = args.stateUrl.replace(/\/$/, "");
  console.error(
    `Scanning AO schedule slots ${from}..${to} (${batch} slots/request)...`,
  );

  for (let end = to; end >= from; end -= batch) {
    const start = Math.max(from, end - batch + 1);
    console.error(`Checking AO slots ${start}..${end}`);
    const url =
      `${state}/${args.token}~process@1.0/schedule?from=${start}` +
      `&to=${end}&accept=application/aos-2`;
    const slot = findMessageSlot(await fetchAny(url, args), args);
    if (Number.isInteger(slot)) return slot;
  }

  throw new Error(
    `Could not find ${args.messageId} in AO schedule slots ${from}..${to}. ` +
      "It may not be scheduled yet; wait and rerun, or pass --slot manually.",
  );
}

const args = parseArgs(process.argv);
if (!args.ledger) {
  throw new Error("--ledger is required");
}
if (!args.slot) {
  console.error("Finding AO schedule slot...");
  args.slot = String(await findSlot(args));
  console.error(`Found AO slot: ${args.slot}`);
}
const base = args.node.replace(/\/$/, "");
const params = new URLSearchParams({
  token: args.token,
  "message-id": args.messageId,
  slot: args.slot,
  sender: args.sender,
  quantity: args.quantity,
});
if (args.ledger) {
  params.set("ledger", args.ledger);
}
if (args.recipient) {
  params.set("recipient", args.recipient);
}

const path = args.verifyOnly ? "verify" : "ingest";
const res = await fetchWithTimeout(
  `${base}/~ao-payment@1.0/${path}?${params}`,
  {
    method: "POST",
    headers: { accept: "application/json" },
  },
  Number(args.timeout),
);
const body = await res.text();
if (!res.ok) {
  throw new Error(`~ao-payment@1.0/${path} failed (${res.status}): ${body}`);
}
console.log(body);

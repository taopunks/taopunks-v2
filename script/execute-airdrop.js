/**
 * TAO Punks V2 — Airdrop Execution Script
 *
 * Reads the snapshot, builds the ordered recipient array (3,333 entries),
 * replaces team wallets with the burn address, and executes airdropBatch()
 * in chunks.
 *
 * Usage:
 *   node execute-airdrop.js <V2_CONTRACT_ADDRESS>
 *
 * Requires: PRIVATE_KEY in ../.env
 */

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ── Config ──
const RPC = 'http://localhost:9944';
const CHAIN_ID = 964;
const BURN_ADDRESS = '0x000000000000000000000000000000000000dEaD';
const BATCH_SIZE = 100; // tokens per transaction
const SNAPSHOT_FILE = path.join(__dirname, '../../taopunks-report/SNAPSHOT_2026-04-16T20-20-18.json');

// 3 confirmed team wallets to burn
const TEAM_WALLETS = new Set([
  '0x58c9c00e55d563c1d53e910f3a5bcd2f9a1220d6', // Deployer
  '0xc68a53fd2afd3f4947052e87235166a334c677a9', // Team #2
  '0xdc97b0e48f1c4b2f1f8802883f9430b214310d41', // Team #3
]);

// ── Load env ──
const envPath = path.join(__dirname, '../../.env');
const envContent = fs.readFileSync(envPath, 'utf8');
const PRIVATE_KEY = envContent.match(/^PRIVATE_KEY=(.+)$/m)?.[1]?.trim();
if (!PRIVATE_KEY) { console.error('PRIVATE_KEY not found in .env'); process.exit(1); }

// ── Get V2 contract address from CLI arg ──
const V2_ADDRESS = process.argv[2];
if (!V2_ADDRESS || !V2_ADDRESS.startsWith('0x')) {
  console.error('Usage: node execute-airdrop.js <V2_CONTRACT_ADDRESS>');
  process.exit(1);
}

// ── RPC helpers ──
let rpcId = 0;

function rpcCall(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params });
    const url = new URL(RPC);
    const proto = url.protocol === 'https:' ? https : http;
    const req = proto.request({
      hostname: url.hostname, port: url.port, path: url.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch(e) { reject(e); } });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ── Signing helpers (minimal EIP-155) ──
const { createHash } = crypto;

function keccak256(data) {
  // Use ethers-style keccak via node crypto won't work - need to shell out
  // Actually, for signing transactions we need proper libs. Let's use a simple approach.
  return null; // placeholder
}

// Instead of reimplementing signing, let's use forge cast for sending txs
async function sendTx(to, data) {
  return new Promise((resolve, reject) => {
    const { execSync } = require('child_process');
    const forge = 'C:/Users/Compl/.foundry/bin/cast.exe';
    try {
      const result = execSync(
        `${forge} send "${to}" "${data}" --private-key "${PRIVATE_KEY}" --rpc-url "${RPC}" --legacy`,
        { encoding: 'utf8', timeout: 120000 }
      );
      // Extract tx hash
      const hashMatch = result.match(/transactionHash\s+(0x[a-fA-F0-9]{64})/);
      resolve(hashMatch ? hashMatch[1] : result.trim());
    } catch(e) {
      reject(new Error(e.stderr || e.message));
    }
  });
}

async function castSend(to, sig, args) {
  return new Promise((resolve, reject) => {
    const { execSync } = require('child_process');
    const cast = 'C:/Users/Compl/.foundry/bin/cast.exe';
    const cmd = `${cast} send "${to}" "${sig}" ${args} --private-key "${PRIVATE_KEY}" --rpc-url "${RPC}" --legacy`;
    try {
      const result = execSync(cmd, { encoding: 'utf8', timeout: 300000 });
      const hashMatch = result.match(/transactionHash\s+(0x[a-fA-F0-9]{64})/);
      resolve(hashMatch ? hashMatch[1] : result.trim());
    } catch(e) {
      reject(new Error(e.stderr || e.message));
    }
  });
}

// Encode address array for airdropBatch(address[])
function encodeAddressArray(addresses) {
  // ABI encode: function selector + offset + length + addresses
  // airdropBatch(address[]) selector
  const selector = 'airdropBatch(address[])';
  // We'll use cast to handle encoding, passing addresses as arguments
  return addresses.map(a => `"${a}"`).join(' ');
}

async function main() {
  console.log('═══════════════════════════════════════════════');
  console.log('  TAO Punks V2 — Airdrop Execution');
  console.log('═══════════════════════════════════════════════');
  console.log('');

  // Load snapshot
  console.log('Loading snapshot...');
  const snapshot = JSON.parse(fs.readFileSync(SNAPSHOT_FILE, 'utf8'));
  const tokenOwnerMap = snapshot.tokenOwnerMap;
  console.log(`  Snapshot: ${snapshot.snapshotTimestamp}`);
  console.log(`  Tokens: ${Object.keys(tokenOwnerMap).length}`);
  console.log('');

  // Build ordered recipient array (token ID 1 -> 3333)
  const recipients = [];
  let burnCount = 0;
  let airdropCount = 0;

  for (let id = 1; id <= 3333; id++) {
    const owner = tokenOwnerMap[id]?.toLowerCase();
    if (!owner) {
      console.error(`ERROR: No owner found for token ${id}`);
      process.exit(1);
    }
    if (TEAM_WALLETS.has(owner)) {
      recipients.push(BURN_ADDRESS);
      burnCount++;
    } else {
      recipients.push(owner);
      airdropCount++;
    }
  }

  console.log(`Recipients built: ${recipients.length} total`);
  console.log(`  Community airdrop: ${airdropCount} tokens`);
  console.log(`  Team burn (to dead): ${burnCount} tokens`);
  console.log(`  V2 Contract: ${V2_ADDRESS}`);
  console.log('');

  // Show which team tokens will be burned
  console.log('Team tokens being burned:');
  for (let id = 1; id <= 3333; id++) {
    const owner = tokenOwnerMap[id]?.toLowerCase();
    if (TEAM_WALLETS.has(owner)) {
      console.log(`  Token #${id} (held by ${owner}) -> BURN`);
    }
  }
  console.log('');

  // Check current supply on V2
  const supplyRes = await rpcCall('eth_call', [{ to: V2_ADDRESS, data: '0x18160ddd' }, 'latest']);
  const currentSupply = parseInt(supplyRes.result, 16);
  console.log(`V2 current totalSupply: ${currentSupply}`);

  if (currentSupply > 0) {
    console.log(`Resuming from token ID ${currentSupply + 1}...`);
  }

  // Execute in batches
  const startFrom = currentSupply; // index into recipients array
  const totalBatches = Math.ceil((recipients.length - startFrom) / BATCH_SIZE);
  console.log(`\nExecuting ${totalBatches} batch transactions (${BATCH_SIZE} per batch)...`);
  console.log('');

  for (let batch = 0; batch < totalBatches; batch++) {
    const start = startFrom + batch * BATCH_SIZE;
    const end = Math.min(start + BATCH_SIZE, recipients.length);
    const batchRecipients = recipients.slice(start, end);
    const startId = start + 1;
    const endId = end;

    console.log(`Batch ${batch + 1}/${totalBatches}: tokens ${startId}-${endId} (${batchRecipients.length} tokens)...`);

    // Build the cast send command with the address array
    // cast send <contract> "airdropBatch(address[])" "[addr1,addr2,...]"
    const addrArrayStr = '[' + batchRecipients.join(',') + ']';

    try {
      const txHash = await castSend(V2_ADDRESS, 'airdropBatch(address[])', `"${addrArrayStr}"`);
      console.log(`  TX: ${txHash}`);
    } catch(e) {
      console.error(`  FAILED: ${e.message}`);
      console.error(`  Stopping at batch ${batch + 1}. Re-run to resume from token ${end + 1}.`);
      process.exit(1);
    }

    // Small delay between batches
    if (batch < totalBatches - 1) {
      await new Promise(r => setTimeout(r, 2000));
    }
  }

  console.log('\n═══════════════════════════════════════════════');
  console.log('  Airdrop complete!');
  console.log('═══════════════════════════════════════════════');

  // Verify final supply
  const finalSupplyRes = await rpcCall('eth_call', [{ to: V2_ADDRESS, data: '0x18160ddd' }, 'latest']);
  const finalSupply = parseInt(finalSupplyRes.result, 16);
  console.log(`\nV2 totalSupply: ${finalSupply}`);
  console.log(`Expected: 3333`);
  console.log(`Match: ${finalSupply === 3333 ? 'YES' : 'NO !!!'}`);

  // Now finalize
  if (finalSupply === 3333) {
    console.log('\nFinalizing airdrop (permanently locking minting)...');
    try {
      const finalizeTx = await castSend(V2_ADDRESS, 'finalizeAirdrop()', '');
      console.log(`  Finalize TX: ${finalizeTx}`);
      console.log('\n  Airdrop finalized. No more tokens can ever be minted.');
    } catch(e) {
      console.error(`  Finalize FAILED: ${e.message}`);
      console.error('  Run manually: cast send <V2> "finalizeAirdrop()" ...');
    }
  }

  // Save airdrop log
  const log = {
    timestamp: new Date().toISOString(),
    v2Contract: V2_ADDRESS,
    snapshotUsed: SNAPSHOT_FILE,
    totalAirdropped: airdropCount,
    totalBurned: burnCount,
    teamWallets: [...TEAM_WALLETS],
    burnedTokenIds: [],
  };
  for (let id = 1; id <= 3333; id++) {
    if (TEAM_WALLETS.has(tokenOwnerMap[id]?.toLowerCase())) {
      log.burnedTokenIds.push(id);
    }
  }
  fs.writeFileSync(
    path.join(__dirname, '../../taopunks-report/airdrop-execution-log.json'),
    JSON.stringify(log, null, 2)
  );
  console.log('\nExecution log saved to taopunks-report/airdrop-execution-log.json');
}

main().catch(e => { console.error('FATAL:', e); process.exit(1); });

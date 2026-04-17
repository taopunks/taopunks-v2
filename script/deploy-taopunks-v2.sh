#!/bin/bash
# Deploy TaoPunksV2 to Bittensor EVM (Chain 964)

PRIVATE_KEY=$(grep '^PRIVATE_KEY=' ../.env | cut -d'=' -f2- | tr -d '\r\n')
FORGE="C:/Users/Compl/.foundry/bin/forge.exe"
RPC="http://localhost:9944"

# The deployer address will be the initial owner
# Base URI = original TAO Punks IPFS metadata CID
BASE_URI="ipfs://bafybeielhkzlrzz6dhz4ixgtywf43s3z7mdpk4fysaqapehz3bijck6cqa/"

echo "═══════════════════════════════════════════════"
echo "  Deploying TaoPunksV2 to Bittensor EVM"
echo "═══════════════════════════════════════════════"
echo ""
echo "Base URI: $BASE_URI"
echo "RPC: $RPC"
echo ""

# Get deployer address from private key
DEPLOYER=$(node -e "
const { createPublicClient, http } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');
const account = privateKeyToAccount('$PRIVATE_KEY');
console.log(account.address);
" 2>/dev/null || echo "UNKNOWN")

echo "Deployer/Owner: $DEPLOYER"
echo ""
echo "Press Ctrl+C to cancel, or wait 5 seconds to deploy..."
sleep 5

$FORGE create src/TaoPunksV2.sol:TaoPunksV2 \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC" \
  --legacy \
  --broadcast \
  --constructor-args "$DEPLOYER" "$BASE_URI"

echo ""
echo "Done. Save the contract address above."
echo "Next step: Run the airdrop script."

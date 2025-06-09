#!/bin/bash
set -euox pipefail

# Install Foundry before running it

# ========= Configuration =========

# RPC endpoints and keys (update with your actual values)
DAS_RPC_URL="http://das-server:9876"
OWNER_PRIVATE_KEY="REDACTED"

UPGRADE_EXECUTOR_ADDRESS="0x6bD5e06dE628DA4eCC536993F28c1dCd5aEf441E" # parent chain
SEQUENCER_INBOX_ADDRESS="0x4365a7e18F5Fd672e57445239Ca49700dcdc6D13"

# Parent chain RPC URL for data availability
PARENT_CHAIN_RPC="https://internal-arbitrum-sepolia-net.zeeve.net/Dwmc5q4EXoA3zu5o3v/rpc"

# Directories for keys and DAS data
BASE_DIR="./config"
BLS_PATH="$BASE_DIR/keys"

# Nitro image version (update if needed)
NITRO_IMAGE="offchainlabs/nitro-node:v3.2.1-d81324d"

# ========= Prepare Directories =========

mkdir -p "$BLS_PATH"
chmod -fR 777 "$BLS_PATH"

# ========= Generate BLS Keypair =========

echo "Generating BLS keypair..."
docker run --rm -v "$BASE_DIR":/data --entrypoint /usr/local/bin/datool "$NITRO_IMAGE" keygen --dir /data/keys

# ========= Read Public Key =========

PUB_KEY_FILE="$BLS_PATH/das_bls.pub"
if [[ ! -f "$PUB_KEY_FILE" ]]; then
    echo "Error: Public key file not found at $PUB_KEY_FILE"
    exit 1
fi

PUB_KEY=$(tr -d '\n' < "$PUB_KEY_FILE")
echo "Public key: $PUB_KEY"

# ========= Create DAC Config JSON =========

cat > "$BASE_DIR/dac-config.json" <<EOF
{
  "keyset": {
    "assumed-honest": 1,
    "backends": [
      {
        "url": "$DAS_RPC_URL",
        "pubkey": "$PUB_KEY"
      }
    ]
  }
}
EOF

echo "DAC config created: $(realpath dac-config.json)"

# ========= Dump Keyset and Extract =========

echo "Dumping keyset..."
key_set_res=$(docker run --rm -v "$BASE_DIR":/data --entrypoint /usr/local/bin/datool "$NITRO_IMAGE" dumpkeyset --conf.file /data/dac-config.json)

# Extract keyset using awk (adjust the extraction if your output format changes)
keyset=$(echo "$key_set_res" | awk -F'Keyset: ' '{print $2}' | awk '{print $1}')
if [[ -z "$keyset" ]]; then
    echo "Error: Failed to extract keyset from dumpkeyset output."
    exit 1
fi
echo "Extracted keyset: $keyset"

# ========= Encode Function Call Data =========

# Encode the function call data for "setValidKeyset(bytes)"
echo "Encoding function call data for setValidKeyset..."
function_call_data=$(cast calldata "setValidKeyset(bytes)" "$keyset")
echo "Encoded function call data: $function_call_data"

# ========= Execute Upgrade Transaction =========

echo "Sending upgrade transaction..."
cast send "$UPGRADE_EXECUTOR_ADDRESS" \
  "executeCall(address,bytes)" \
  "$SEQUENCER_INBOX_ADDRESS" "$function_call_data" \
  --rpc-url "$PARENT_CHAIN_RPC" \
  --private-key "$OWNER_PRIVATE_KEY" \

echo "Upgrade transaction sent."

echo "Update config/nodeConfig.json with the following:

Replace:
  http://localhost:9877 -> http://das-server:9877
  http://localhost:9876 -> http://das-server:9876

And set:
  pubkey: $PUB_KEY"

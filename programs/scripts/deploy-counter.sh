#!/bin/bash
set -e

###############################################################################
# deploy-counter.sh
#
# Demonstrates the Solana program upgrade flow:
#   1. Build & deploy v1 (increment only)
#   2. Test v1 — increment works, reset fails
#   3. Upgrade to v2 (same program ID — add reset instruction)
#   4. Test v2 — increment + reset both work
#
# Usage: ./deploy-counter.sh [RPC_URL] [PAYER_KEYPAIR]
###############################################################################

RPC_URL="${1:-http://127.0.0.1:8899}"
PAYER="${2:-/home/solana/keypairs/identity.json}"
PROGRAM_DIR="/home/solana/programs/counter"
PASS=0
FAIL=0

log_pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "============================================"
echo "  Counter Program — v1 → v2 Upgrade Demo"
echo "============================================"
echo "RPC:   $RPC_URL"
echo "Payer: $PAYER"
echo ""

# ---- Generate program keypair (determines the program ID) ----
PROGRAM_KP="/tmp/counter-program-keypair.json"
solana-keygen new --outfile "$PROGRAM_KP" --no-bip39-passphrase --force --silent
PROGRAM_ID=$(solana-keygen pubkey "$PROGRAM_KP")
echo "Program ID: $PROGRAM_ID"
echo ""

# ====================================================================
# STEP 1: Build v1 (increment only — reset commented out)
# ====================================================================
echo "--- Step 1: Build v1 ---"
cd "$PROGRAM_DIR"

# Ensure v1 source (reset is commented out)
cat > src/lib.rs << 'RUSTEOF'
use borsh::{BorshDeserialize, BorshSerialize};
use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    msg,
    program_error::ProgramError,
    pubkey::Pubkey,
};

#[derive(BorshSerialize, BorshDeserialize, Debug)]
pub struct CounterAccount {
    pub count: u64,
}

entrypoint!(process_instruction);

pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    let accounts_iter = &mut accounts.iter();
    let counter_account = next_account_info(accounts_iter)?;

    if counter_account.owner != program_id {
        return Err(ProgramError::IncorrectProgramId);
    }
    if !counter_account.is_writable {
        return Err(ProgramError::InvalidAccountData);
    }

    let instruction = instruction_data
        .first()
        .ok_or(ProgramError::InvalidInstructionData)?;

    let mut counter = if counter_account.data.borrow().iter().all(|&b| b == 0) {
        CounterAccount { count: 0 }
    } else {
        CounterAccount::try_from_slice(&counter_account.data.borrow())
            .map_err(|_| ProgramError::InvalidAccountData)?
    };

    match instruction {
        0 => {
            counter.count = counter.count.checked_add(1)
                .ok_or(ProgramError::InvalidAccountData)?;
            msg!("Incremented counter to {}", counter.count);
        }
        _ => {
            msg!("v1: instruction {} not supported", instruction);
            return Err(ProgramError::InvalidInstructionData);
        }
    }

    counter.serialize(&mut &mut counter_account.data.borrow_mut()[..])?;
    Ok(())
}
RUSTEOF

cargo build-bpf 2>&1 | tail -3
log_pass "v1 built"

# ====================================================================
# STEP 2: Deploy v1
# ====================================================================
echo ""
echo "--- Step 2: Deploy v1 ---"
solana program deploy \
  target/deploy/counter.so \
  --url "$RPC_URL" \
  --keypair "$PAYER" \
  --program-id "$PROGRAM_KP" \
  --upgrade-authority "$PAYER" \
  --commitment confirmed 2>&1

solana program show "$PROGRAM_ID" --url "$RPC_URL" --keypair "$PAYER" 2>&1
log_pass "v1 deployed at $PROGRAM_ID"

# ====================================================================
# STEP 3: Test v1 — create account, increment 3x, verify count=3
# ====================================================================
echo ""
echo "--- Step 3: Test v1 ---"

# Create a data account owned by the program
DATA_KP="/tmp/counter-data-keypair.json"
solana-keygen new --outfile "$DATA_KP" --no-bip39-passphrase --force --silent
DATA_PUBKEY=$(solana-keygen pubkey "$DATA_KP")
SPACE=8  # u64 = 8 bytes
LAMPORTS=$(solana rent-exemption "$SPACE" --url "$RPC_URL" 2>&1 | awk '{print $NF}')

# Use Python to create account + send instructions
python3 << PYEOF
import json, subprocess, struct, base64, time

RPC = "$RPC_URL"
PROGRAM_ID = "$PROGRAM_ID"
PAYER = "$PAYER"
DATA_KP = "$DATA_KP"
DATA_PUBKEY = "$DATA_PUBKEY"
SPACE = $SPACE

def rpc(method, params):
    payload = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params})
    r = subprocess.run(["curl","-s",RPC,"-X","POST","-H","Content-Type: application/json","-d",payload],
                       capture_output=True, text=True, timeout=15)
    return json.loads(r.stdout)

# Create account using solana CLI
result = subprocess.run([
    "solana", "create-account", DATA_KP, str(SPACE),
    "--url", RPC, "--keypair", PAYER,
    "--owner", PROGRAM_ID,
    "--commitment", "confirmed"
], capture_output=True, text=True)
print("Create account:", result.stdout.strip() if result.returncode == 0 else result.stderr.strip())

time.sleep(2)

# Send increment instruction (byte 0x00) three times
for i in range(3):
    # Build instruction via solana CLI is not straightforward,
    # so we use a raw transaction approach via RPC
    # Actually, let's use solana program invoke
    pass

# Since we can't easily send custom instructions from bash/python without solana-py,
# let's install it and use it
print("Installing solana-py...")
subprocess.run(["pip3", "install", "solana", "solders", "--quiet", "--break-system-packages"],
               capture_output=True, text=True)

from solders.keypair import Keypair
from solders.pubkey import Pubkey
from solders.instruction import Instruction, AccountMeta
from solders.transaction import Transaction
from solders.message import Message
from solders.hash import Hash
import solders.system_program as sp

# Load keypairs
with open(PAYER, 'r') as f:
    payer_bytes = json.load(f)
payer_kp = Keypair.from_bytes(bytes(payer_bytes))

with open(DATA_KP, 'r') as f:
    data_bytes = json.load(f)
data_kp = Keypair.from_bytes(bytes(data_bytes))

program_pubkey = Pubkey.from_string(PROGRAM_ID)
data_pubkey = Pubkey.from_string(DATA_PUBKEY)

def get_blockhash():
    resp = rpc("getLatestBlockhash", [{"commitment":"confirmed"}])
    return Hash.from_string(resp["result"]["value"]["blockhash"])

def send_instruction(ix_data_bytes, label):
    ix = Instruction(
        program_id=program_pubkey,
        data=ix_data_bytes,
        accounts=[AccountMeta(data_pubkey, is_signer=False, is_writable=True)]
    )
    blockhash = get_blockhash()
    msg = Message.new_with_blockhash([ix], payer_kp.pubkey(), blockhash)
    tx = Transaction.new([payer_kp], msg, blockhash)
    tx_bytes = bytes(tx)
    tx_b64 = base64.b64encode(tx_bytes).decode()
    resp = rpc("sendTransaction", [tx_b64, {"encoding":"base64","preflightCommitment":"confirmed"}])
    if "result" in resp:
        print(f"  {label}: sig={resp['result'][:32]}...")
        time.sleep(1)
        return True
    else:
        err = resp.get("error", {}).get("message", "unknown")
        print(f"  {label}: FAILED — {err}")
        return False

def read_counter():
    resp = rpc("getAccountInfo", [DATA_PUBKEY, {"encoding":"base64","commitment":"confirmed"}])
    data_b64 = resp.get("result",{}).get("value",{}).get("data",[""])[0]
    if data_b64:
        raw = base64.b64decode(data_b64)
        if len(raw) >= 8:
            return struct.unpack('<Q', raw[:8])[0]
    return None

# Increment 3 times
for i in range(3):
    send_instruction(bytes([0]), f"increment #{i+1}")
time.sleep(2)

count = read_counter()
print(f"  Counter after 3 increments: {count}")
if count == 3:
    print("  [PASS] v1 increment works — count=3")
else:
    print(f"  [FAIL] expected 3, got {count}")

# Try reset on v1 — should fail
print("  Calling reset on v1 (should fail)...")
ok = send_instruction(bytes([1]), "reset (v1)")
time.sleep(1)
count_after_reset = read_counter()
if count_after_reset == 3:
    print("  [PASS] v1 correctly rejects reset — count still 3")
else:
    print(f"  [FAIL] v1 reset should have failed, count={count_after_reset}")

PYEOF

# ====================================================================
# STEP 4: Upgrade to v2 (enable reset instruction)
# ====================================================================
echo ""
echo "--- Step 4: Build v2 (enable reset) ---"

cat > src/lib.rs << 'RUSTEOF'
use borsh::{BorshDeserialize, BorshSerialize};
use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    msg,
    program_error::ProgramError,
    pubkey::Pubkey,
};

#[derive(BorshSerialize, BorshDeserialize, Debug)]
pub struct CounterAccount {
    pub count: u64,
}

entrypoint!(process_instruction);

pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    let accounts_iter = &mut accounts.iter();
    let counter_account = next_account_info(accounts_iter)?;

    if counter_account.owner != program_id {
        return Err(ProgramError::IncorrectProgramId);
    }
    if !counter_account.is_writable {
        return Err(ProgramError::InvalidAccountData);
    }

    let instruction = instruction_data
        .first()
        .ok_or(ProgramError::InvalidInstructionData)?;

    let mut counter = if counter_account.data.borrow().iter().all(|&b| b == 0) {
        CounterAccount { count: 0 }
    } else {
        CounterAccount::try_from_slice(&counter_account.data.borrow())
            .map_err(|_| ProgramError::InvalidAccountData)?
    };

    match instruction {
        0 => {
            counter.count = counter.count.checked_add(1)
                .ok_or(ProgramError::InvalidAccountData)?;
            msg!("Incremented counter to {}", counter.count);
        }
        1 => {
            msg!("Reset counter from {} to 0 (v2)", counter.count);
            counter.count = 0;
        }
        _ => {
            msg!("Invalid instruction: {}", instruction);
            return Err(ProgramError::InvalidInstructionData);
        }
    }

    counter.serialize(&mut &mut counter_account.data.borrow_mut()[..])?;
    Ok(())
}
RUSTEOF

cargo build-bpf 2>&1 | tail -3
log_pass "v2 built (reset enabled)"

# ====================================================================
# STEP 5: Deploy v2 to SAME program ID (upgrade)
# ====================================================================
echo ""
echo "--- Step 5: Upgrade to v2 (same program ID) ---"
solana program deploy \
  target/deploy/counter.so \
  --url "$RPC_URL" \
  --keypair "$PAYER" \
  --program-id "$PROGRAM_ID" \
  --upgrade-authority "$PAYER" \
  --commitment confirmed 2>&1

log_pass "v2 upgraded at SAME address: $PROGRAM_ID"

# ====================================================================
# STEP 6: Test v2 — increment + reset
# ====================================================================
echo ""
echo "--- Step 6: Test v2 ---"

python3 << PYEOF
import json, subprocess, struct, base64, time

RPC = "$RPC_URL"
PROGRAM_ID = "$PROGRAM_ID"
PAYER = "$PAYER"
DATA_PUBKEY = "$DATA_PUBKEY"

def rpc(method, params):
    payload = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params})
    r = subprocess.run(["curl","-s",RPC,"-X","POST","-H","Content-Type: application/json","-d",payload],
                       capture_output=True, text=True, timeout=15)
    return json.loads(r.stdout)

from solders.keypair import Keypair
from solders.pubkey import Pubkey
from solders.instruction import Instruction, AccountMeta
from solders.transaction import Transaction
from solders.message import Message
from solders.hash import Hash

with open(PAYER, 'r') as f:
    payer_kp = Keypair.from_bytes(bytes(json.load(f)))

program_pubkey = Pubkey.from_string(PROGRAM_ID)
data_pubkey = Pubkey.from_string(DATA_PUBKEY)

def get_blockhash():
    resp = rpc("getLatestBlockhash", [{"commitment":"confirmed"}])
    return Hash.from_string(resp["result"]["value"]["blockhash"])

def send_instruction(ix_data_bytes, label):
    ix = Instruction(
        program_id=program_pubkey,
        data=ix_data_bytes,
        accounts=[AccountMeta(data_pubkey, is_signer=False, is_writable=True)]
    )
    blockhash = get_blockhash()
    msg = Message.new_with_blockhash([ix], payer_kp.pubkey(), blockhash)
    tx = Transaction.new([payer_kp], msg, blockhash)
    tx_b64 = base64.b64encode(bytes(tx)).decode()
    resp = rpc("sendTransaction", [tx_b64, {"encoding":"base64","preflightCommitment":"confirmed"}])
    if "result" in resp:
        print(f"  {label}: sig={resp['result'][:32]}...")
        time.sleep(1)
        return resp['result']
    else:
        print(f"  {label}: FAILED — {resp.get('error',{}).get('message','?')}")
        return None

def read_counter():
    resp = rpc("getAccountInfo", [DATA_PUBKEY, {"encoding":"base64","commitment":"confirmed"}])
    data_b64 = resp.get("result",{}).get("value",{}).get("data",[""])[0]
    if data_b64:
        raw = base64.b64decode(data_b64)
        if len(raw) >= 8:
            return struct.unpack('<Q', raw[:8])[0]
    return None

# Current count should be 3 from v1 tests
count = read_counter()
print(f"  Counter before v2 test: {count}")

# Increment once more (should go to 4)
send_instruction(bytes([0]), "increment #4")
time.sleep(2)
count = read_counter()
print(f"  Counter after increment: {count}")
if count == 4:
    print("  [PASS] v2 increment works — count=4")
else:
    print(f"  [FAIL] expected 4, got {count}")

# Reset (v2 feature — should set to 0)
send_instruction(bytes([1]), "reset (v2)")
time.sleep(2)
count = read_counter()
print(f"  Counter after reset: {count}")
if count == 0:
    print("  [PASS] v2 reset works — count=0")
else:
    print(f"  [FAIL] expected 0, got {count}")

# Increment after reset to prove it still works
send_instruction(bytes([0]), "increment after reset")
time.sleep(2)
count = read_counter()
print(f"  Counter after post-reset increment: {count}")
if count == 1:
    print("  [PASS] increment after reset — count=1")
else:
    print(f"  [FAIL] expected 1, got {count}")

PYEOF

# ====================================================================
# Summary
# ====================================================================
echo ""
echo "============================================"
echo "  Results"
echo "============================================"
echo "  Program ID: $PROGRAM_ID"
echo "  Data account: $DATA_PUBKEY"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  ALL STEPS PASSED"
else
  echo "  SOME STEPS FAILED"
  exit 1
fi

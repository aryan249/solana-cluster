# Counter Program v1 → v2 Upgrade Walkthrough

**Cluster:** Private Solana v1.18.15 (ap-south-1)
**Program ID:** `93zKzqfn2we4JBLLYDbrutuMkrwjbKYHfHKrW2en68gK`
**Upgrade Authority:** `8NJfVKG9B5DG1G9h1ynf2X1xpd1rTXqaYZQPffgxmF64`

---

## 1. The Program (Rust)

A minimal Solana program that stores a `u64` counter in an on-chain account (8 bytes).

### v1 — Increment Only

```rust
match instruction {
    0 => {
        count = count + 1;
        msg!("Incremented counter to {}", count);
    }
    _ => {
        msg!("v1: instruction {} not supported", instruction);
        return Err(ProgramError::InvalidInstructionData);
    }
}
```

v1 only handles instruction byte `0` (increment). Any other instruction — including `1` (reset) — is rejected with `InvalidInstructionData`.

### v2 — Increment + Reset

```rust
match instruction {
    0 => {
        count = count + 1;
        msg!("Incremented counter to {}", count);
    }
    1 => {
        msg!("Reset counter from {} to 0 (v2)", count);
        count = 0;
    }
    _ => {
        msg!("Invalid instruction: {}", instruction);
        return Err(ProgramError::InvalidInstructionData);
    }
}
```

v2 adds a new match arm for instruction byte `1` (reset). Same program, same address — just updated bytecode.

---

## 2. Build

The program is built using the Solana BPF toolchain:

```bash
cargo-build-sbf    # produces target/deploy/counter.so
```

This compiles Rust into a BPF binary (`.so`) that runs on Solana's Sealevel VM.

---

## 3. Deploy v1

```bash
# Generate a program keypair (determines the program address)
solana-keygen new --outfile /tmp/counter-program-keypair.json --no-bip39-passphrase --force

# Deploy v1
solana program deploy target/deploy/counter.so \
  --url http://127.0.0.1:8899 \
  --keypair /home/solana/keypairs/identity.json \
  --program-id /tmp/counter-program-keypair.json \
  --upgrade-authority /home/solana/keypairs/identity.json
```

Key flags:
- `--program-id` — the keypair whose public key becomes the program address
- `--upgrade-authority` — sets who can upgrade the program later

Result:
```
Program Id: 93zKzqfn2we4JBLLYDbrutuMkrwjbKYHfHKrW2en68gK
Last Deployed In Slot: 819
Owner: BPFLoaderUpgradeab1e11111111111111111111111
```

---

## 4. Test v1

### Create a data account

The counter needs an on-chain account to store its state (8 bytes for a `u64`):

```python
create_ix = create_account(CreateAccountParams(
    from_pubkey=payer.pubkey(),
    to_pubkey=data_account.pubkey(),
    lamports=rent_exemption_for_8_bytes,
    space=8,
    owner=program_id
))
```

### Increment 3 times

```python
for i in range(3):
    send_instruction(bytes([0]))   # instruction byte 0 = increment
```

Result: counter = 3

```
  increment #1: tx=4FE1aXT8HKnuujqpBamnUcRzT5E3wa4hemW83gtW...
  increment #2: tx=3WwEDXSmDRbWvGFVuC68FzrsBbn2xtGuxuJbQ8xi...
  increment #3: tx=2UHSEp3LX3RDXcXX3GPeCL5twbtxPnEZj7Xp2ZCL...
  Counter after 3 increments: 3
  [PASS] v1 increment x3 = 3
```

### Try reset on v1 — should fail

```python
send_instruction(bytes([1]))   # instruction byte 1 = reset
```

Result: Transaction rejected with `InvalidInstructionData`, counter stays at 3.

```
  reset (v1 — should fail): FAILED — Transaction simulation failed:
    Error processing Instruction 0: invalid instruction data
  [PASS] v1 rejects reset — count still 3
```

---

## 5. Upgrade to v2

### Modify source code

The only change: add a match arm for instruction `1` in `lib.rs`:

```rust
1 => {
    msg!("Reset counter from {} to 0 (v2)", count);
    count = 0;
}
```

### Rebuild

```bash
cargo-build-sbf    # produces updated target/deploy/counter.so
```

### Deploy v2 to SAME program ID

```bash
solana program deploy target/deploy/counter.so \
  --url http://127.0.0.1:8899 \
  --keypair /home/solana/keypairs/identity.json \
  --program-id 93zKzqfn2we4JBLLYDbrutuMkrwjbKYHfHKrW2en68gK \
  --upgrade-authority /home/solana/keypairs/identity.json
```

The critical difference from v1 deploy: `--program-id` takes the **existing program address string** (not a keypair file). Solana replaces the bytecode at that address.

Result:
```
Program Id: 93zKzqfn2we4JBLLYDbrutuMkrwjbKYHfHKrW2en68gK   ← SAME address
Last Deployed In Slot: 1733                                   ← updated slot
Data Length: 22720 bytes                                      ← slightly larger (reset code added)
```

What the upgrade preserves:
- Same program ID
- Same data accounts and their state
- Same upgrade authority
- Counter value was still 3 (carried over from v1)

What changed:
- Bytecode (the `.so` binary)
- Deployment slot (819 → 1733)

---

## 6. Test v2

### Increment (state preserved)

```python
send_instruction(bytes([0]))   # increment
```

Counter went from 3 (v1 state) to 4 — state preserved across upgrade.

```
  Counter before v2 test: 3
  increment #4: tx=4FuMpaWufTzMxGfbW9HMSs4K52SmSKWXxPAUiJtH...
  Counter: 4
  [PASS] v2 increment — count=4
```

### Reset (new v2 instruction)

```python
send_instruction(bytes([1]))   # reset
```

Counter went to 0 — the new v2 instruction works.

```
  reset (v2): tx=yRNBkxDkMWzxTgdwVHfii3RAB7B6KUhcDJdmsqhR...
  Counter after reset: 0
  [PASS] v2 reset works — count=0
```

### Increment after reset

```python
send_instruction(bytes([0]))   # increment
```

Counter went to 1 — everything works correctly.

```
  increment after reset: tx=2tc5TZ1xJRQWbkEA5QcTe8CEbBNstCZ4zRUxy7We...
  Counter: 1
  [PASS] increment after reset — count=1
```

---

## 7. Results

| Test | Instruction | Expected | Actual | Result |
|------|------------|----------|--------|--------|
| v1: Increment x3 | `[0]` x3 | count=3 | count=3 | PASS |
| v1: Reset rejected | `[1]` | Error | InvalidInstructionData | PASS |
| v2: Increment | `[0]` | count=4 | count=4 | PASS |
| v2: Reset | `[1]` | count=0 | count=0 | PASS |
| v2: Increment after reset | `[0]` | count=1 | count=1 | PASS |

**All 5 assertions passed. Program upgrade verified.**

---

## 8. How Solana Program Upgrades Work

Solana uses the `BPFLoaderUpgradeab1e` program loader which supports in-place upgrades:

1. **Program Account** — stores metadata (authority, deployment slot)
2. **ProgramData Account** — stores the actual bytecode
3. **Upgrade Authority** — the keypair that controls who can upgrade

When you run `solana program deploy --program-id EXISTING_ID`:
- The loader verifies the signer matches the upgrade authority
- The old bytecode in the ProgramData account is replaced with the new bytecode
- The program address stays the same
- All existing data accounts remain untouched
- The next transaction that invokes the program uses the new bytecode

This is how real programs are upgraded on Solana mainnet (e.g., Serum, Marinade, Jupiter). The upgrade authority can also be set to `None` to make a program immutable (non-upgradeable).

---

## 9. Transaction Hashes

All transactions are verifiable on the cluster:

**v1 Deploy:**
```
Program Id: 93zKzqfn2we4JBLLYDbrutuMkrwjbKYHfHKrW2en68gK
Slot: 819
```

**v2 Upgrade:**
```
Signature: 39ZJAs5tPMqbPeFJZX76SL2yWkgYpSRYw6xTu1bEgm2oAdnciGVbDFiV9an92XET84JsBsqQ6SyZmJG1MJxvvFg5
Slot: 1733
```

**Test Transactions:**
```
Create account:     39K1xNqvpWuapzJrGYc1ZA56TCtUjALuaQ7bMSz8...
v1 increment #1:    4FE1aXT8HKnuujqpBamnUcRzT5E3wa4hemW83gtW...
v1 increment #2:    3WwEDXSmDRbWvGFVuC68FzrsBbn2xtGuxuJbQ8xi...
v1 increment #3:    2UHSEp3LX3RDXcXX3GPeCL5twbtxPnEZj7Xp2ZCL...
v2 increment #4:    4FuMpaWufTzMxGfbW9HMSs4K52SmSKWXxPAUiJtH...
v2 reset:           yRNBkxDkMWzxTgdwVHfii3RAB7B6KUhcDJdmsqhR...
v2 increment #5:    2tc5TZ1xJRQWbkEA5QcTe8CEbBNstCZ4zRUxy7We...
```

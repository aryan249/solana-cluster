# Blockchain Infrastructure: L1, L2, and Solana Internals

## Layer 1 vs Layer 2: Transaction Lifecycle

A Layer 1 (L1) blockchain is the base settlement layer. On Ethereum, a transaction follows this path: the user signs a transaction and submits it to a node's mempool. Validators (post-Merge, proof-of-stake validators) pick transactions from the mempool, order them, and include them in a block proposal. The block goes through attestation by a committee of validators. After two epochs of attestation (roughly 12.8 minutes), the block achieves finality and the transaction is irreversible on the L1.

A Layer 2 (L2) is a scaling construct that executes transactions off the L1 but posts proofs or data back to the L1 for security. On an L2 rollup, the user submits a transaction to the L2 sequencer. The sequencer orders transactions, executes them against the L2 state, and produces a batch. That batch is compressed and posted to the L1 as calldata (or, post-EIP-4844, as blob data). The L1 smart contract holds the L2 state root. The critical question is how the L1 verifies correctness of the L2 state transitions, and this divides rollups into two categories.

## Optimistic Rollups vs ZK Rollups

Optimistic rollups assume all L2 state transitions are valid unless challenged. After a batch is posted to L1, there is a dispute window (typically 7 days on Optimism and Arbitrum). During this window, any observer can submit a fraud proof if they believe the state transition is incorrect.

The fraud proof mechanism on Arbitrum uses a bisection game. The challenger and the sequencer interactively narrow down the disputed execution to a single instruction. The L1 contract then re-executes that single instruction on-chain. If the sequencer's result does not match, the batch is reverted and the sequencer is slashed. This interactive bisection is logarithmic in the number of instructions, making it gas-efficient on L1.

ZK rollups take the opposite approach: they generate a cryptographic validity proof (a zk-SNARK or zk-STARK) for every batch. The L1 contract verifies this proof, which is a constant-time operation regardless of the number of transactions in the batch. This eliminates the dispute window entirely---finality on L1 is achieved as soon as the proof is verified. The tradeoff is proof generation cost: producing a ZK proof is computationally expensive and introduces latency on the L2 side. Projects like zkSync and StarkNet are actively optimizing prover performance.

## The Sequencer and Centralization Risk

In both rollup types, the sequencer is the entity that orders L2 transactions and produces batches. Today, most rollups operate with a single centralized sequencer run by the rollup team. This creates several risks: the sequencer can censor transactions (refuse to include them), extract MEV (reorder transactions for profit), and represents a single point of failure (if the sequencer goes offline, no new L2 blocks are produced).

Mitigations exist. Most rollups implement a forced inclusion mechanism: if the sequencer censors a transaction, the user can submit it directly to the L1 contract after a timeout. Shared sequencer designs (such as Espresso) propose a decentralized set of sequencers that rotate leadership, analogous to L1 validator sets. Based rollups take this further by using the L1 validators themselves as sequencers, inheriting the L1's decentralization properties at the cost of L1 block time latency.

## Solana Proof of History

Proof of History (PoH) is Solana's mechanism for establishing a cryptographic clock that orders events before consensus. It is a sequential SHA-256 hash chain: each hash takes the previous hash as input, producing a verifiable sequence where the only way to generate hash N is to have computed hashes 1 through N-1. This creates a verifiable delay function---you cannot parallelize or shortcut the computation.

Why does this matter? In traditional BFT consensus, validators must communicate to agree on the ordering of events. This communication overhead limits throughput. PoH provides a pre-consensus ordering: the leader validator tags each transaction with its position in the hash chain. Other validators can verify the ordering by checking the hash chain, without needing to communicate with each other about order. This reduces consensus from an ordering problem to a confirmation problem, allowing Solana to process transactions in parallel while maintaining a deterministic order.

Each PoH tick corresponds to a fixed number of SHA-256 hashes. Solana targets 6250 microseconds per tick and 64 ticks per slot, yielding a slot time of approximately 400 milliseconds.

## Tower BFT and the Lockout Mechanism

Tower BFT is Solana's consensus algorithm, built on top of PoH. It is a PBFT-like protocol optimized by using the PoH clock as a source of time rather than relying on network timeouts.

When a validator votes on a slot, that vote carries a lockout that doubles with each consecutive vote on the same fork. The first vote has a lockout of 2 slots, the second 4, then 8, 16, and so on. A validator cannot switch to a different fork until its lockout expires. This exponential lockout means that after 32 consecutive votes on a fork, the validator is locked in for 2^32 slots (roughly 54 years), making the fork effectively irreversible.

This mechanism achieves finality without an explicit finality gadget. Once a supermajority (two-thirds) of stake has voted on a fork with deep lockouts, that fork is finalized. The PoH clock allows validators to calculate lockout expiration locally without network round trips, which is why Tower BFT achieves faster finality than classical PBFT implementations.

## Turbine Block Propagation

Turbine is Solana's block propagation protocol, inspired by BitTorrent. Rather than the leader broadcasting the entire block to every validator (which scales linearly with validator count), Turbine breaks the block into shreds (small packets, typically 1280 bytes each) and organizes validators into a tree structure.

The leader sends shreds to a small set of validators in the first layer. Each of those validators retransmits the shreds to a set of validators in the next layer, and so on. With a fanout of 200 and 1000 validators, the entire block reaches all validators in two hops. Shreds use erasure coding (Reed-Solomon) so that validators can reconstruct missing shreds without retransmission from the leader. This reduces the leader's bandwidth requirement from O(n) to O(fanout) and reduces propagation latency to O(log n) hops.

## Gulf Stream Transaction Forwarding

Gulf Stream is Solana's mempool-less transaction forwarding protocol. In traditional blockchains, transactions sit in a mempool until a block producer picks them up. In Solana, the leader schedule is known in advance (computed at the start of each epoch), so clients and validators can forward transactions directly to the upcoming leader.

When a validator receives a transaction, it checks the leader schedule and forwards it to the current or next expected leader via TPU (Transaction Processing Unit) on port 8004. This eliminates mempool management overhead, reduces confirmation latency (the transaction is already at the leader when their slot arrives), and reduces the amount of data validators need to hold in memory.

## Sealevel Parallel Execution

Sealevel is Solana's parallel smart contract runtime. Unlike the EVM, which executes transactions serially, Sealevel can execute multiple transactions simultaneously across available CPU cores.

This is possible because of Solana's account model. Every Solana transaction must declare upfront which accounts it will read from and which it will write to. The runtime uses this information to build a dependency graph: transactions that touch disjoint sets of accounts can run in parallel, while transactions that write to the same account must be serialized. This is conceptually similar to a database scheduler using read-write locks.

## Solana vs Ethereum Account Model

Ethereum uses an account-based model where each account has a balance, nonce, code (for contracts), and storage (a key-value store). Smart contract state lives inside the contract's storage trie. This means a single contract call implicitly accesses whatever storage slots the code touches, and these dependencies are not known until execution.

Solana separates code from state. Programs (the equivalent of smart contracts) are stateless executable code stored in program accounts. All state is stored in data accounts, which are separate from the program. A transaction must explicitly list every account it interacts with, whether for reading or writing. This explicit declaration is what enables Sealevel's parallel execution. The tradeoff is developer complexity: Solana programs must manage account creation, sizing, and rent, whereas Ethereum contracts can allocate storage dynamically.

Solana accounts also have a rent mechanism. Accounts must maintain a minimum balance proportional to their data size (the rent-exempt minimum, currently approximately 0.00089 SOL per byte-epoch). Accounts that fall below this balance are purged. In practice, most accounts are made rent-exempt by depositing sufficient lamports at creation.

## Fee Structure

Ethereum uses a gas-based fee model. Each EVM opcode has a gas cost, and users bid a gas price. Post-EIP-1559, fees have a base fee (burned) and a priority fee (paid to validators). Gas prices fluctuate with demand, and complex contract interactions can cost hundreds of dollars during congestion.

Solana uses a fixed base fee of 5000 lamports (0.000005 SOL) per signature, regardless of computation complexity. Priority fees can be added to increase the probability of inclusion during congestion. Compute units (analogous to gas) are budgeted per transaction (default 200,000, maximum 1,400,000) but do not affect the base fee. This makes Solana fees predictable and typically sub-cent.

## Finality Guarantees

Ethereum achieves probabilistic finality after one block (12 seconds) and economic finality after two epochs (12.8 minutes), at which point reversing the chain would require slashing at least one-third of all staked ETH.

Solana achieves optimistic confirmation after approximately 400ms (a single slot, once a supermajority of validators have voted). Full finality (rooted) occurs after 32 confirmations, which takes roughly 13 seconds. The Tower BFT lockout mechanism provides the economic guarantee: validators that vote on a finalized fork and then attempt to switch would lose their stake.

## Cluster Topology

A Solana cluster consists of several node types and on-chain structures:

**Validator nodes** participate in consensus. Each validator runs the `solana-validator` process, which maintains a copy of the ledger, produces blocks when scheduled as leader, and votes on other leaders' blocks. Validators require an identity keypair (for signing votes and blocks) and a vote account (an on-chain account that tracks the validator's voting history).

**RPC nodes** run the same software as validators but do not vote or produce blocks. They serve the JSON-RPC API to external clients, providing read access to the ledger and accepting transaction submissions. RPC nodes can be scaled horizontally behind a load balancer.

**Vote accounts** are on-chain accounts (owned by the Vote program) that record a validator's voting history, commission rate, and authorized voter keys. Creating a vote account requires a transaction signed by the validator's identity key.

**Stake accounts** are on-chain accounts (owned by the Stake program) that delegate SOL to a vote account. Stake activation takes one full epoch. The amount of stake delegated to a validator determines its weight in consensus and its probability of being selected as leader.

**Leader schedule** is computed deterministically at the start of each epoch based on stake weights. The schedule assigns four consecutive slots to each leader. All validators compute the same schedule independently from the same stake snapshot, so no communication is needed to agree on who leads which slots.

**Epochs** are fixed-length periods of 432,000 slots on mainnet (approximately 2-3 days). At epoch boundaries, stake activations and deactivations take effect, the leader schedule for the next epoch is computed, and rewards are distributed. In this private cluster, epochs are set to 432 slots for faster iteration during testing.

In this project's cluster topology, the bootstrap validator initializes the genesis ledger and serves as the initial leader. Three additional validators join via gossip, receive the genesis configuration, and begin voting. The RPC node connects to the cluster for serving external queries. The faucet provides SOL airdrops for testing. All nodes communicate over gossip (port 8001) for cluster state, TPU (port 8004) for transaction forwarding, and TVU (port 8005) for block propagation via Turbine.

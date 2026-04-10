package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	mrand "math/rand"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/mr-tron/base58"
)

// ============================================================================
// Types
// ============================================================================

type TxResult struct {
	Signature   string
	SubmittedAt time.Time
	ConfirmedAt time.Time
	Status      string // "confirmed", "failed", "dropped"
	Error       string
	LatencyMs   int64
}

type Report struct {
	TotalSubmitted         int            `json:"total_submitted"`
	TotalConfirmed         int            `json:"total_confirmed"`
	TotalFailed            int            `json:"total_failed"`
	TotalDropped           int            `json:"total_dropped"`
	SubmissionsPerSecond   float64        `json:"submissions_per_second"`
	ConfirmationsPerSecond float64        `json:"confirmations_per_second"`
	LatencyP50Ms           int64          `json:"latency_p50_ms"`
	LatencyP90Ms           int64          `json:"latency_p90_ms"`
	LatencyP99Ms           int64          `json:"latency_p99_ms"`
	LatencyMaxMs           int64          `json:"latency_max_ms"`
	TotalDurationSeconds   float64        `json:"total_duration_seconds"`
	RpcErrors              map[string]int `json:"rpc_errors"`
	WalletsUsed            int            `json:"wallets_used"`
	Concurrency            int            `json:"concurrency"`
	RpcEndpoint            string         `json:"rpc_endpoint"`
}

type Wallet struct {
	PrivateKey ed25519.PrivateKey
	PublicKey  ed25519.PublicKey
}

type job struct {
	sender   Wallet
	receiver ed25519.PublicKey
}

type config struct {
	wallets      int
	transactions int
	concurrency  int
	rpc          string
	timeout      int
	output       string
	funder       string // path to JSON keypair file for funding wallets
}

// ============================================================================
// Solana wire format — compact-u16 encoding
// ============================================================================

func encodeCompactU16(val int) []byte {
	if val < 0x80 {
		return []byte{byte(val)}
	}
	if val < 0x4000 {
		return []byte{byte(val&0x7f | 0x80), byte(val >> 7)}
	}
	return []byte{byte(val&0x7f | 0x80), byte((val>>7)&0x7f | 0x80), byte(val >> 14)}
}

// ============================================================================
// Transaction building — manual serialization
// ============================================================================

// System Program ID: all zeros (base58 = "11111111111111111111111111111111")
var systemProgramID = make([]byte, 32)

// buildTransferTx constructs a signed SOL transfer transaction from scratch.
//
// Solana legacy transaction wire format:
//
//	Transaction = compact-u16(num_sigs) || sig[0..] || Message
//	Message     = header(3 bytes) || compact-u16(num_keys) || keys[0..] ||
//	              blockhash(32) || compact-u16(num_ix) || instructions[0..]
//	Instruction = u8(program_idx) || compact-u16(num_accts) || acct_indices ||
//	              compact-u16(data_len) || data
//
// Transfer instruction data = u32_le(2) || u64_le(lamports)   (12 bytes)
func buildTransferTx(sender Wallet, receiver ed25519.PublicKey, lamports uint64, recentBlockhash []byte) []byte {
	// Transfer instruction data: index 2 (Transfer) + lamports
	instrData := make([]byte, 12)
	binary.LittleEndian.PutUint32(instrData[0:4], 2)
	binary.LittleEndian.PutUint64(instrData[4:12], lamports)

	// --- Build message ---
	var msg bytes.Buffer

	// Header: [num_required_signatures, num_readonly_signed, num_readonly_unsigned]
	// sender = signer+writable, receiver = writable, system_program = readonly
	msg.Write([]byte{1, 0, 1})

	// Account keys: [sender, receiver, system_program]
	msg.Write(encodeCompactU16(3))
	msg.Write(sender.PublicKey) // 32 bytes
	msg.Write(receiver)         // 32 bytes
	msg.Write(systemProgramID)  // 32 bytes

	// Recent blockhash
	msg.Write(recentBlockhash) // 32 bytes

	// Instructions: 1 instruction
	msg.Write(encodeCompactU16(1))

	// Compiled instruction
	msg.WriteByte(2)                            // program_id_index = 2
	msg.Write(encodeCompactU16(2))              // 2 account indices
	msg.Write([]byte{0, 1})                     // sender=0, receiver=1
	msg.Write(encodeCompactU16(len(instrData))) // data length
	msg.Write(instrData)                        // instruction data

	msgBytes := msg.Bytes()

	// --- Sign message ---
	sig := ed25519.Sign(sender.PrivateKey, msgBytes)

	// --- Assemble transaction ---
	var tx bytes.Buffer
	tx.Write(encodeCompactU16(1)) // 1 signature
	tx.Write(sig)                 // 64 bytes
	tx.Write(msgBytes)

	return tx.Bytes()
}

// ============================================================================
// JSON-RPC helpers (net/http only, no SDK)
// ============================================================================

type rpcRequest struct {
	Jsonrpc string      `json:"jsonrpc"`
	ID      int         `json:"id"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

type rpcResponse struct {
	Jsonrpc string          `json:"jsonrpc"`
	ID      int             `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

var httpClient = &http.Client{Timeout: 30 * time.Second}

func rpcCall(ctx context.Context, rpcURL, method string, params interface{}) (json.RawMessage, error) {
	body, err := json.Marshal(rpcRequest{
		Jsonrpc: "2.0",
		ID:      1,
		Method:  method,
		Params:  params,
	})
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", rpcURL, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("new request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("http: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read body: %w", err)
	}

	var rpcResp rpcResponse
	if err := json.Unmarshal(respBody, &rpcResp); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}

	if rpcResp.Error != nil {
		return nil, fmt.Errorf("rpc error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}

	return rpcResp.Result, nil
}

func getLatestBlockhash(ctx context.Context, rpcURL string) ([]byte, error) {
	result, err := rpcCall(ctx, rpcURL, "getLatestBlockhash", []interface{}{
		map[string]string{"commitment": "confirmed"},
	})
	if err != nil {
		return nil, err
	}

	var parsed struct {
		Value struct {
			Blockhash string `json:"blockhash"`
		} `json:"value"`
	}
	if err := json.Unmarshal(result, &parsed); err != nil {
		return nil, fmt.Errorf("parse: %w", err)
	}

	return base58.Decode(parsed.Value.Blockhash)
}

func sendTransaction(ctx context.Context, rpcURL string, txBase64 string) (string, error) {
	result, err := rpcCall(ctx, rpcURL, "sendTransaction", []interface{}{
		txBase64,
		map[string]interface{}{
			"encoding":            "base64",
			"skipPreflight":       true,
			"preflightCommitment": "confirmed",
		},
	})
	if err != nil {
		return "", err
	}

	var sig string
	if err := json.Unmarshal(result, &sig); err != nil {
		return "", fmt.Errorf("parse sig: %w", err)
	}
	return sig, nil
}

func getSignatureStatus(ctx context.Context, rpcURL string, sig string) (string, error) {
	result, err := rpcCall(ctx, rpcURL, "getSignatureStatuses", []interface{}{
		[]string{sig},
		map[string]bool{"searchTransactionHistory": true},
	})
	if err != nil {
		return "", err
	}

	var parsed struct {
		Value []json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(result, &parsed); err != nil {
		return "", fmt.Errorf("parse: %w", err)
	}

	if len(parsed.Value) == 0 || string(parsed.Value[0]) == "null" {
		return "pending", nil
	}

	var status struct {
		ConfirmationStatus string      `json:"confirmationStatus"`
		Err                interface{} `json:"err"`
	}
	if err := json.Unmarshal(parsed.Value[0], &status); err != nil {
		return "", fmt.Errorf("parse status: %w", err)
	}

	if status.Err != nil {
		return "failed", nil
	}
	if status.ConfirmationStatus == "confirmed" || status.ConfirmationStatus == "finalized" {
		return "confirmed", nil
	}
	return "pending", nil
}

func requestAirdrop(ctx context.Context, rpcURL string, pubkey string, lamports uint64) (string, error) {
	result, err := rpcCall(ctx, rpcURL, "requestAirdrop", []interface{}{pubkey, lamports})
	if err != nil {
		return "", err
	}

	var sig string
	if err := json.Unmarshal(result, &sig); err != nil {
		return "", fmt.Errorf("parse sig: %w", err)
	}
	return sig, nil
}

// ============================================================================
// Pre-flight: wallet generation and funding
// ============================================================================

func generateWallets(n int) []Wallet {
	wallets := make([]Wallet, n)
	for i := 0; i < n; i++ {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Fatal: generate keypair: %v\n", err)
			os.Exit(1)
		}
		wallets[i] = Wallet{PrivateKey: priv, PublicKey: pub}
	}
	return wallets
}

func pubkeyBase58(pub ed25519.PublicKey) string {
	return base58.Encode(pub)
}

// loadKeypairFromFile loads a Solana CLI-format keypair JSON (array of 64 bytes).
func loadKeypairFromFile(path string) (Wallet, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Wallet{}, fmt.Errorf("read keypair file: %w", err)
	}

	var keyBytes []byte
	if err := json.Unmarshal(data, &keyBytes); err != nil {
		return Wallet{}, fmt.Errorf("parse keypair JSON: %w", err)
	}

	if len(keyBytes) != 64 {
		return Wallet{}, fmt.Errorf("keypair must be 64 bytes, got %d", len(keyBytes))
	}

	priv := ed25519.PrivateKey(keyBytes)
	pub := priv.Public().(ed25519.PublicKey)
	return Wallet{PrivateKey: priv, PublicKey: pub}, nil
}

// waitForSig polls getSignatureStatuses until confirmed or timeout.
func waitForSig(ctx context.Context, rpcURL string, sig string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return false
		}
		sCtx, sCancel := context.WithTimeout(ctx, 5*time.Second)
		status, err := getSignatureStatus(sCtx, rpcURL, sig)
		sCancel()
		if err == nil && status == "confirmed" {
			return true
		}
		if err == nil && status == "failed" {
			return false
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

// fundWalletsViaTransfer funds wallets by sending SOL from the funder keypair.
func fundWalletsViaTransfer(ctx context.Context, rpcURL string, funder Wallet, wallets []Wallet) []Wallet {
	var funded []Wallet

	for i, w := range wallets {
		addr := pubkeyBase58(w.PublicKey)
		ok := false

		for attempt := 0; attempt < 2; attempt++ {
			// Get fresh blockhash
			bhCtx, bhCancel := context.WithTimeout(ctx, 5*time.Second)
			bh, err := getLatestBlockhash(bhCtx, rpcURL)
			bhCancel()
			if err != nil {
				fmt.Printf("  wallet %d attempt %d: get blockhash: %s\n", i+1, attempt+1, err)
				continue
			}

			// Build transfer: 1 SOL to wallet
			txBytes := buildTransferTx(funder, w.PublicKey, 1_000_000_000, bh)
			txBase64 := base64.StdEncoding.EncodeToString(txBytes)

			sendCtx, sendCancel := context.WithTimeout(ctx, 10*time.Second)
			sig, err := sendTransaction(sendCtx, rpcURL, txBase64)
			sendCancel()
			if err != nil {
				fmt.Printf("  wallet %d attempt %d: send: %s\n", i+1, attempt+1, err)
				continue
			}

			if waitForSig(ctx, rpcURL, sig, 30*time.Second) {
				ok = true
				break
			}
		}

		if ok {
			funded = append(funded, w)
			fmt.Printf("  wallet %d/%d funded (%s...)\n", i+1, len(wallets), addr[:8])
		} else {
			fmt.Printf("  wallet %d/%d SKIPPED\n", i+1, len(wallets))
		}
	}
	return funded
}

// fundWalletsViaAirdrop funds wallets using the RPC faucet (requestAirdrop).
func fundWalletsViaAirdrop(ctx context.Context, rpcURL string, wallets []Wallet) []Wallet {
	var funded []Wallet

	for i, w := range wallets {
		addr := pubkeyBase58(w.PublicKey)
		ok := false

		for attempt := 0; attempt < 2; attempt++ {
			aCtx, aCancel := context.WithTimeout(ctx, 30*time.Second)
			sig, err := requestAirdrop(aCtx, rpcURL, addr, 1_000_000_000) // 1 SOL
			aCancel()
			if err != nil {
				fmt.Printf("  wallet %d airdrop attempt %d: %s\n", i+1, attempt+1, err)
				continue
			}

			if waitForSig(ctx, rpcURL, sig, 30*time.Second) {
				ok = true
				break
			}
		}

		if ok {
			funded = append(funded, w)
			fmt.Printf("  wallet %d/%d funded (%s...)\n", i+1, len(wallets), addr[:8])
		} else {
			fmt.Printf("  wallet %d/%d SKIPPED\n", i+1, len(wallets))
		}
	}
	return funded
}

// ============================================================================
// Worker pool
// ============================================================================

func worker(
	ctx context.Context,
	rpcURL string,
	jobs <-chan job,
	results chan<- TxResult,
	txTimeout time.Duration,
	submitted, confirmed, failed, dropped *int64,
	wg *sync.WaitGroup,
) {
	defer wg.Done()

	var (
		cachedBlockhash []byte
		txCount         int
	)

	for j := range jobs {
		// Check for cancellation before each job
		select {
		case <-ctx.Done():
			results <- TxResult{Status: "dropped", Error: "context cancelled"}
			atomic.AddInt64(dropped, 1)
			continue
		default:
		}

		r := TxResult{}

		// Refresh blockhash every 10 transactions per worker
		if txCount%10 == 0 || cachedBlockhash == nil {
			bhCtx, bhCancel := context.WithTimeout(ctx, 5*time.Second)
			bh, err := getLatestBlockhash(bhCtx, rpcURL)
			bhCancel()
			if err != nil {
				r.Status = "failed"
				r.Error = fmt.Sprintf("get blockhash: %s", err)
				atomic.AddInt64(failed, 1)
				results <- r
				txCount++
				continue
			}
			cachedBlockhash = bh
		}

		// Build and sign transaction
		txBytes := buildTransferTx(j.sender, j.receiver, 1000, cachedBlockhash)
		txBase64 := base64.StdEncoding.EncodeToString(txBytes)

		// Send transaction
		sendCtx, sendCancel := context.WithTimeout(ctx, 10*time.Second)
		sig, err := sendTransaction(sendCtx, rpcURL, txBase64)
		sendCancel()

		r.SubmittedAt = time.Now()

		if err != nil {
			r.Status = "failed"
			r.Error = fmt.Sprintf("send: %s", err)
			atomic.AddInt64(failed, 1)
			results <- r
			txCount++
			continue
		}

		r.Signature = sig
		atomic.AddInt64(submitted, 1)

		// Poll for confirmation
		deadline := time.Now().Add(txTimeout)
		for time.Now().Before(deadline) {
			if ctx.Err() != nil {
				break
			}

			pCtx, pCancel := context.WithTimeout(ctx, 5*time.Second)
			status, err := getSignatureStatus(pCtx, rpcURL, sig)
			pCancel()

			if err != nil {
				time.Sleep(500 * time.Millisecond)
				continue
			}

			if status == "confirmed" {
				r.ConfirmedAt = time.Now()
				r.Status = "confirmed"
				r.LatencyMs = r.ConfirmedAt.Sub(r.SubmittedAt).Milliseconds()
				atomic.AddInt64(confirmed, 1)
				break
			}
			if status == "failed" {
				r.Status = "failed"
				r.Error = "transaction failed on-chain"
				atomic.AddInt64(failed, 1)
				break
			}

			time.Sleep(500 * time.Millisecond)
		}

		// If still no status after polling, mark as dropped
		if r.Status == "" {
			r.Status = "dropped"
			r.Error = "confirmation timeout"
			atomic.AddInt64(dropped, 1)
		}

		results <- r
		txCount++
	}
}

// ============================================================================
// Live progress printer
// ============================================================================

func progressPrinter(
	start time.Time,
	submitted, confirmed, failed, dropped *int64,
	done <-chan struct{},
) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			s := atomic.LoadInt64(submitted)
			c := atomic.LoadInt64(confirmed)
			f := atomic.LoadInt64(failed)
			d := atomic.LoadInt64(dropped)
			inFlight := s - c - f - d
			if inFlight < 0 {
				inFlight = 0
			}
			elapsed := time.Since(start).Seconds()
			fmt.Printf("[%.1fs] submitted=%d confirmed=%d in-flight=%d failed=%d dropped=%d\n",
				elapsed, s, c, inFlight, f, d)
		}
	}
}

// ============================================================================
// Report generation
// ============================================================================

func percentile(sorted []int64, pct float64) int64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(float64(len(sorted)) * pct / 100.0)
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func buildReport(results []TxResult, cfg config, duration time.Duration) Report {
	report := Report{
		RpcErrors:   make(map[string]int),
		WalletsUsed: cfg.wallets,
		Concurrency: cfg.concurrency,
		RpcEndpoint: cfg.rpc,
	}

	var latencies []int64

	for _, r := range results {
		switch r.Status {
		case "confirmed":
			report.TotalSubmitted++
			report.TotalConfirmed++
			latencies = append(latencies, r.LatencyMs)
		case "failed":
			if r.Signature != "" {
				report.TotalSubmitted++
			}
			report.TotalFailed++
			if r.Error != "" {
				report.RpcErrors[r.Error]++
			}
		case "dropped":
			if r.Signature != "" {
				report.TotalSubmitted++
			}
			report.TotalDropped++
		}
	}

	dur := duration.Seconds()
	report.TotalDurationSeconds = dur
	if dur > 0 {
		report.SubmissionsPerSecond = float64(report.TotalSubmitted) / dur
		report.ConfirmationsPerSecond = float64(report.TotalConfirmed) / dur
	}

	if len(latencies) > 0 {
		sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
		report.LatencyP50Ms = percentile(latencies, 50)
		report.LatencyP90Ms = percentile(latencies, 90)
		report.LatencyP99Ms = percentile(latencies, 99)
		report.LatencyMaxMs = latencies[len(latencies)-1]
	}

	return report
}

func printReport(r Report) {
	fmt.Println()
	fmt.Println("=== Results ===")
	fmt.Printf("Total submitted:          %d\n", r.TotalSubmitted)
	fmt.Printf("Total confirmed:          %d\n", r.TotalConfirmed)
	fmt.Printf("Total failed:             %d\n", r.TotalFailed)
	fmt.Printf("Total dropped:            %d\n", r.TotalDropped)
	fmt.Printf("Submissions/sec:          %.1f\n", r.SubmissionsPerSecond)
	fmt.Printf("Confirmations/sec:        %.1f\n", r.ConfirmationsPerSecond)
	fmt.Printf("Latency p50:              %dms\n", r.LatencyP50Ms)
	fmt.Printf("Latency p90:              %dms\n", r.LatencyP90Ms)
	fmt.Printf("Latency p99:              %dms\n", r.LatencyP99Ms)
	fmt.Printf("Latency max:              %dms\n", r.LatencyMaxMs)
	fmt.Printf("Total duration:           %.2fs\n", r.TotalDurationSeconds)

	if len(r.RpcErrors) > 0 {
		fmt.Println("\nRPC Errors:")
		for msg, count := range r.RpcErrors {
			fmt.Printf("  [%d] %s\n", count, msg)
		}
	}
}

func writeReportJSON(path string, r Report) error {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

// ============================================================================
// Main
// ============================================================================

func main() {
	var cfg config
	flag.IntVar(&cfg.wallets, "wallets", 10, "Number of sender wallets")
	flag.IntVar(&cfg.transactions, "transactions", 1000, "Total transactions to send")
	flag.IntVar(&cfg.concurrency, "concurrency", 50, "Parallel workers")
	flag.StringVar(&cfg.rpc, "rpc", "", "RPC endpoint URL (required)")
	flag.IntVar(&cfg.timeout, "timeout", 30, "Per-transaction timeout seconds")
	flag.StringVar(&cfg.output, "output", "", "Path to write JSON report")
	flag.StringVar(&cfg.funder, "funder", "", "Path to Solana keypair JSON for funding wallets (skips airdrop)")
	flag.Parse()

	if cfg.rpc == "" {
		fmt.Fprintln(os.Stderr, "Error: --rpc is required")
		flag.Usage()
		os.Exit(1)
	}

	// --- Banner ---
	fmt.Println("=== Solana Cluster Stress Test ===")
	fmt.Printf("RPC:          %s\n", cfg.rpc)
	fmt.Printf("Wallets:      %d\n", cfg.wallets)
	fmt.Printf("Transactions: %d\n", cfg.transactions)
	fmt.Printf("Concurrency:  %d\n", cfg.concurrency)
	fmt.Println()

	// Top-level context — cancelled on SIGINT/SIGTERM
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	// =====================================================================
	// Step 1 — Pre-flight: generate keypairs and fund via airdrop
	// =====================================================================

	fmt.Println("Pre-flight: funding wallets...")
	wallets := generateWallets(cfg.wallets)

	var funded []Wallet
	if cfg.funder != "" {
		funder, err := loadKeypairFromFile(cfg.funder)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Fatal: load funder keypair: %s\n", err)
			os.Exit(1)
		}
		fmt.Printf("  Funder: %s\n", pubkeyBase58(funder.PublicKey))
		funded = fundWalletsViaTransfer(ctx, cfg.rpc, funder, wallets)
	} else {
		funded = fundWalletsViaAirdrop(ctx, cfg.rpc, wallets)
	}
	fmt.Printf("Pre-flight: funded %d/%d wallets\n\n", len(funded), cfg.wallets)

	if len(funded) < 2 {
		fmt.Fprintln(os.Stderr, "Error: fewer than 2 wallets funded, aborting")
		os.Exit(1)
	}

	// Update wallets count to reflect actual funded wallets
	cfg.wallets = len(funded)

	// =====================================================================
	// Step 2 — Worker pool: channels and goroutines
	// =====================================================================

	jobs := make(chan job, cfg.transactions)
	resultsCh := make(chan TxResult, cfg.transactions)

	var (
		atomicSubmitted int64
		atomicConfirmed int64
		atomicFailed    int64
		atomicDropped   int64
	)

	txTimeout := time.Duration(cfg.timeout) * time.Second

	var workerWg sync.WaitGroup
	for i := 0; i < cfg.concurrency; i++ {
		workerWg.Add(1)
		go worker(
			ctx, cfg.rpc, jobs, resultsCh, txTimeout,
			&atomicSubmitted, &atomicConfirmed, &atomicFailed, &atomicDropped,
			&workerWg,
		)
	}

	// =====================================================================
	// Step 4 — Live progress printer
	// =====================================================================

	startTime := time.Now()
	progressDone := make(chan struct{})
	go progressPrinter(startTime, &atomicSubmitted, &atomicConfirmed, &atomicFailed, &atomicDropped, progressDone)

	fmt.Println("Starting test...")

	// =====================================================================
	// Step 2 cont. — Push all jobs into channel
	// =====================================================================

	go func() {
		rng := mrand.New(mrand.NewSource(time.Now().UnixNano()))
		for i := 0; i < cfg.transactions; i++ {
			senderIdx := rng.Intn(len(funded))
			receiverIdx := rng.Intn(len(funded))
			for receiverIdx == senderIdx && len(funded) > 1 {
				receiverIdx = rng.Intn(len(funded))
			}

			select {
			case jobs <- job{
				sender:   funded[senderIdx],
				receiver: funded[receiverIdx].PublicKey,
			}:
			case <-ctx.Done():
				break
			}
		}
		close(jobs)
	}()

	// =====================================================================
	// Step 6 — Graceful shutdown + result collection
	// =====================================================================

	// Close resultsCh when all workers finish
	go func() {
		workerWg.Wait()
		close(resultsCh)
	}()

	allResults := make([]TxResult, 0, cfg.transactions)
	interrupted := false

collectLoop:
	for {
		select {
		case r, ok := <-resultsCh:
			if !ok {
				break collectLoop
			}
			allResults = append(allResults, r)

		case sig := <-sigCh:
			fmt.Printf("\nReceived %s — shutting down gracefully...\n", sig)
			interrupted = true
			cancel()
			// Drain remaining results with 5s deadline
			drainDeadline := time.After(5 * time.Second)
		drainLoop:
			for {
				select {
				case r, ok := <-resultsCh:
					if !ok {
						break drainLoop
					}
					allResults = append(allResults, r)
				case <-drainDeadline:
					break drainLoop
				}
			}
			break collectLoop
		}
	}

	close(progressDone)
	totalDuration := time.Since(startTime)

	// =====================================================================
	// Step 5 — Build and print report
	// =====================================================================

	report := buildReport(allResults, cfg, totalDuration)

	if interrupted {
		fmt.Println("\n*** PARTIAL REPORT (interrupted) ***")
	}

	printReport(report)

	if cfg.output != "" {
		if err := writeReportJSON(cfg.output, report); err != nil {
			fmt.Fprintf(os.Stderr, "Error writing report: %s\n", err)
			os.Exit(1)
		}
		fmt.Printf("\nReport written to: %s\n", cfg.output)
	}

	if interrupted {
		os.Exit(130)
	}
}

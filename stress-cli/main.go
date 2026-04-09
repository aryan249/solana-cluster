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
	"math"
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

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Wallet struct {
	PrivateKey ed25519.PrivateKey
	PublicKey  ed25519.PublicKey
}

func (w *Wallet) PubkeyBase58() string {
	return base58.Encode(w.PublicKey)
}

type TxResult struct {
	Signature   string
	SubmittedAt time.Time
	ConfirmedAt time.Time
	Status      string // "confirmed", "failed", "dropped", "timeout"
	Error       string
	LatencyMs   int64
}

type Report struct {
	TotalSubmitted         int            `json:"total_submitted"`
	TotalConfirmed         int            `json:"total_confirmed"`
	TotalFailed            int            `json:"total_failed"`
	TotalDropped           int            `json:"total_dropped"`
	TotalTimedOut          int            `json:"total_timed_out"`
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

// ---------------------------------------------------------------------------
// RPC helpers
// ---------------------------------------------------------------------------

type rpcRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int         `json:"id"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

type rpcResponse struct {
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

var httpClient = &http.Client{Timeout: 30 * time.Second}

func rpcCall(ctx context.Context, rpcURL, method string, params interface{}) (json.RawMessage, error) {
	body, err := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: 1, Method: method, Params: params})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", rpcURL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var rr rpcResponse
	if err := json.Unmarshal(respBody, &rr); err != nil {
		return nil, fmt.Errorf("bad rpc response: %s", string(respBody[:min(len(respBody), 200)]))
	}
	if rr.Error != nil {
		return nil, fmt.Errorf("rpc error %d: %s", rr.Error.Code, rr.Error.Message)
	}
	return rr.Result, nil
}

func getLatestBlockhash(ctx context.Context, rpcURL string) (string, uint64, error) {
	type bhResult struct {
		Value struct {
			Blockhash            string `json:"blockhash"`
			LastValidBlockHeight uint64 `json:"lastValidBlockHeight"`
		} `json:"value"`
	}
	raw, err := rpcCall(ctx, rpcURL, "getLatestBlockhash", []interface{}{map[string]string{"commitment": "confirmed"}})
	if err != nil {
		return "", 0, err
	}
	var r bhResult
	if err := json.Unmarshal(raw, &r); err != nil {
		return "", 0, err
	}
	return r.Value.Blockhash, r.Value.LastValidBlockHeight, nil
}

func sendTransaction(ctx context.Context, rpcURL, txBase64 string) (string, error) {
	raw, err := rpcCall(ctx, rpcURL, "sendTransaction", []interface{}{
		txBase64,
		map[string]interface{}{
			"encoding":             "base64",
			"skipPreflight":        false,
			"preflightCommitment":  "confirmed",
		},
	})
	if err != nil {
		return "", err
	}
	var sig string
	if err := json.Unmarshal(raw, &sig); err != nil {
		return "", err
	}
	return sig, nil
}

func getSignatureStatus(ctx context.Context, rpcURL, sig string) (string, error) {
	type statusResult struct {
		Value []json.RawMessage `json:"value"`
	}
	raw, err := rpcCall(ctx, rpcURL, "getSignatureStatuses", []interface{}{[]string{sig}})
	if err != nil {
		return "", err
	}
	var r statusResult
	if err := json.Unmarshal(raw, &r); err != nil {
		return "", err
	}
	if len(r.Value) == 0 || string(r.Value[0]) == "null" {
		return "pending", nil
	}
	var status struct {
		Err                *json.RawMessage `json:"err"`
		ConfirmationStatus string           `json:"confirmationStatus"`
	}
	if err := json.Unmarshal(r.Value[0], &status); err != nil {
		return "", err
	}
	if status.Err != nil && string(*status.Err) != "null" {
		return "failed", nil
	}
	if status.ConfirmationStatus == "confirmed" || status.ConfirmationStatus == "finalized" {
		return "confirmed", nil
	}
	return "pending", nil
}

func requestAirdrop(ctx context.Context, rpcURL, pubkey string, lamports uint64) (string, error) {
	raw, err := rpcCall(ctx, rpcURL, "requestAirdrop", []interface{}{pubkey, lamports})
	if err != nil {
		return "", err
	}
	var sig string
	if err := json.Unmarshal(raw, &sig); err != nil {
		return "", err
	}
	return sig, nil
}

// ---------------------------------------------------------------------------
// Transaction builder — Solana wire format
// ---------------------------------------------------------------------------

func compactU16(buf *bytes.Buffer, val int) {
	for {
		b := byte(val & 0x7f)
		val >>= 7
		if val > 0 {
			b |= 0x80
		}
		buf.WriteByte(b)
		if val == 0 {
			break
		}
	}
}

func buildSOLTransferTx(sender *Wallet, receiver ed25519.PublicKey, lamports uint64, blockhash string) (string, error) {
	systemProgram := make([]byte, 32) // all zeros = system program

	bhBytes, err := base58.Decode(blockhash)
	if err != nil {
		return "", fmt.Errorf("decode blockhash: %w", err)
	}

	// Build message
	var msg bytes.Buffer
	// Header: numRequiredSigs=1, numReadonlySignedAccounts=0, numReadonlyUnsignedAccounts=1
	msg.Write([]byte{1, 0, 1})
	// Account keys: [sender, receiver, system_program]
	compactU16(&msg, 3)
	msg.Write(sender.PublicKey)
	msg.Write(receiver)
	msg.Write(systemProgram)
	// Recent blockhash
	msg.Write(bhBytes)
	// Instructions: 1 instruction
	compactU16(&msg, 1)
	// Instruction: program_id_index=2 (system program)
	msg.WriteByte(2)
	// Account indices: [0 (sender), 1 (receiver)]
	compactU16(&msg, 2)
	msg.WriteByte(0)
	msg.WriteByte(1)
	// Instruction data: transfer = [2,0,0,0] + le_u64(lamports)
	var ixData bytes.Buffer
	binary.Write(&ixData, binary.LittleEndian, uint32(2)) // transfer instruction index
	binary.Write(&ixData, binary.LittleEndian, lamports)
	compactU16(&msg, ixData.Len())
	msg.Write(ixData.Bytes())

	// Sign
	msgBytes := msg.Bytes()
	sig := ed25519.Sign(sender.PrivateKey, msgBytes)

	// Build transaction
	var tx bytes.Buffer
	compactU16(&tx, 1) // 1 signature
	tx.Write(sig)
	tx.Write(msgBytes)

	return base64.StdEncoding.EncodeToString(tx.Bytes()), nil
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	walletCount := flag.Int("wallets", 10, "Number of sender wallets")
	txCount := flag.Int("transactions", 1000, "Total transactions to send")
	concurrency := flag.Int("concurrency", 50, "Parallel workers")
	txType := flag.String("type", "sol-transfer", "Transaction type: sol-transfer")
	rpcURL := flag.String("rpc", "", "RPC endpoint URL (required)")
	timeout := flag.Int("timeout", 30, "Per-tx confirmation timeout seconds")
	duration := flag.Int("duration", 300, "Max total test duration seconds")
	outputPath := flag.String("output", "", "Path to write JSON report")
	airdropSOL := flag.Float64("airdrop", 1.0, "SOL to airdrop per wallet")
	funderPath := flag.String("funder", "", "Path to funder keypair JSON (uses transfer instead of airdrop)")
	flag.Parse()

	if *rpcURL == "" {
		fmt.Fprintln(os.Stderr, "Error: --rpc is required")
		os.Exit(1)
	}
	if *txType != "sol-transfer" && *txType != "spl-transfer" {
		fmt.Fprintln(os.Stderr, "Error: --type must be sol-transfer or spl-transfer")
		os.Exit(1)
	}

	fmt.Println("=== Solana Cluster Stress Test ===")
	fmt.Printf("RPC:          %s\n", *rpcURL)
	fmt.Printf("Wallets:      %d\n", *walletCount)
	fmt.Printf("Transactions: %d\n", *txCount)
	fmt.Printf("Concurrency:  %d\n", *concurrency)
	fmt.Println()

	// SIGINT handler
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*duration)*time.Second)
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\nReceived interrupt, shutting down gracefully...")
		cancel()
	}()

	// --- Pre-flight: generate and fund wallets ---
	fmt.Println("Pre-flight: generating wallets...")
	wallets := make([]*Wallet, *walletCount)
	for i := range wallets {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			fmt.Fprintf(os.Stderr, "keygen error: %v\n", err)
			os.Exit(1)
		}
		wallets[i] = &Wallet{PrivateKey: priv, PublicKey: pub}
	}

	fmt.Println("Pre-flight: funding wallets...")
	lamportsPerWallet := uint64(*airdropSOL * 1_000_000_000)
	funded := 0
	var fundedWallets []*Wallet

	// Load funder keypair if provided
	var funderWallet *Wallet
	if *funderPath != "" {
		data, err := os.ReadFile(*funderPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading funder keypair: %v\n", err)
			os.Exit(1)
		}
		var keyBytes []byte
		if err := json.Unmarshal(data, &keyBytes); err != nil {
			fmt.Fprintf(os.Stderr, "Error parsing funder keypair: %v\n", err)
			os.Exit(1)
		}
		privKey := ed25519.PrivateKey(keyBytes)
		funderWallet = &Wallet{PrivateKey: privKey, PublicKey: privKey.Public().(ed25519.PublicKey)}
		fmt.Printf("  Using funder: %s\n", funderWallet.PubkeyBase58())
	}

	for i, w := range wallets {
		if ctx.Err() != nil {
			break
		}

		var sig string
		var err error

		if funderWallet != nil {
			// Fund via SOL transfer from funder
			bhCtx, bhCancel := context.WithTimeout(ctx, 10*time.Second)
			bh, _, bhErr := getLatestBlockhash(bhCtx, *rpcURL)
			bhCancel()
			if bhErr != nil {
				fmt.Printf("  wallet %d: blockhash failed: %v\n", i, bhErr)
				continue
			}
			txBase64, txErr := buildSOLTransferTx(funderWallet, w.PublicKey, lamportsPerWallet, bh)
			if txErr != nil {
				fmt.Printf("  wallet %d: build tx failed: %v\n", i, txErr)
				continue
			}
			sendCtx, sendCancel := context.WithTimeout(ctx, 10*time.Second)
			sig, err = sendTransaction(sendCtx, *rpcURL, txBase64)
			sendCancel()
		} else {
			// Fund via airdrop
			aCtx, aCancel := context.WithTimeout(ctx, 15*time.Second)
			sig, err = requestAirdrop(aCtx, *rpcURL, w.PubkeyBase58(), lamportsPerWallet)
			aCancel()
			if err != nil {
				time.Sleep(time.Second)
				aCtx2, aCancel2 := context.WithTimeout(ctx, 15*time.Second)
				sig, err = requestAirdrop(aCtx2, *rpcURL, w.PubkeyBase58(), lamportsPerWallet)
				aCancel2()
			}
		}

		if err != nil {
			fmt.Printf("  wallet %d: funding failed: %v\n", i, err)
			continue
		}
		// Wait for confirmation
		confirmed := false
		for j := 0; j < 30; j++ {
			time.Sleep(500 * time.Millisecond)
			sCtx, sCancel := context.WithTimeout(ctx, 5*time.Second)
			status, _ := getSignatureStatus(sCtx, *rpcURL, sig)
			sCancel()
			if status == "confirmed" {
				confirmed = true
				break
			}
		}
		if confirmed {
			funded++
			fundedWallets = append(fundedWallets, w)
		}
	}
	fmt.Printf("Pre-flight: funded %d/%d wallets\n\n", funded, *walletCount)

	if len(fundedWallets) < 2 {
		fmt.Fprintln(os.Stderr, "Error: need at least 2 funded wallets")
		os.Exit(1)
	}

	// --- Stress test ---
	fmt.Println("Starting test...")
	startTime := time.Now()

	var atomicSubmitted, atomicConfirmed, atomicFailed, atomicDropped, atomicTimedOut int64

	rpcErrors := make(map[string]int)
	var rpcErrorsMu sync.Mutex

	jobs := make(chan int, *txCount)
	results := make(chan TxResult, *txCount)

	for i := 0; i < *txCount; i++ {
		jobs <- i
	}
	close(jobs)

	// Progress printer
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				sub := atomic.LoadInt64(&atomicSubmitted)
				conf := atomic.LoadInt64(&atomicConfirmed)
				fail := atomic.LoadInt64(&atomicFailed)
				drop := atomic.LoadInt64(&atomicDropped)
				inflight := sub - conf - fail - drop
				elapsed := time.Since(startTime).Seconds()
				fmt.Printf("[%.1fs] submitted=%d confirmed=%d in-flight=%d failed=%d dropped=%d\n",
					elapsed, sub, conf, inflight, fail, drop)
			}
		}
	}()

	// Workers
	var wg sync.WaitGroup
	for w := 0; w < *concurrency; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			var cachedBlockhash string
			var txsSinceRefresh int

			for range jobs {
				if ctx.Err() != nil {
					return
				}

				// Refresh blockhash every 10 txs
				if cachedBlockhash == "" || txsSinceRefresh >= 10 {
					bhCtx, bhCancel := context.WithTimeout(ctx, 5*time.Second)
					bh, _, err := getLatestBlockhash(bhCtx, *rpcURL)
					bhCancel()
					if err != nil {
						rpcErrorsMu.Lock()
						rpcErrors["getLatestBlockhash: "+err.Error()]++
						rpcErrorsMu.Unlock()
						results <- TxResult{Status: "failed", Error: err.Error()}
						atomic.AddInt64(&atomicFailed, 1)
						continue
					}
					cachedBlockhash = bh
					txsSinceRefresh = 0
				}
				txsSinceRefresh++

				// Pick random sender and receiver
				senderIdx := mrand.Intn(len(fundedWallets))
				receiverIdx := mrand.Intn(len(fundedWallets))
				for receiverIdx == senderIdx {
					receiverIdx = mrand.Intn(len(fundedWallets))
				}
				sender := fundedWallets[senderIdx]
				receiver := fundedWallets[receiverIdx]

				// Build and sign transaction
				txBase64, err := buildSOLTransferTx(sender, receiver.PublicKey, 1000, cachedBlockhash)
				if err != nil {
					results <- TxResult{Status: "failed", Error: err.Error()}
					atomic.AddInt64(&atomicFailed, 1)
					continue
				}

				// Send
				submittedAt := time.Now()
				sendCtx, sendCancel := context.WithTimeout(ctx, 10*time.Second)
				sig, err := sendTransaction(sendCtx, *rpcURL, txBase64)
				sendCancel()

				if err != nil {
					rpcErrorsMu.Lock()
					rpcErrors[err.Error()]++
					rpcErrorsMu.Unlock()
					results <- TxResult{Status: "failed", Error: err.Error(), SubmittedAt: submittedAt}
					atomic.AddInt64(&atomicFailed, 1)
					continue
				}
				atomic.AddInt64(&atomicSubmitted, 1)

				// Poll for confirmation
				txTimeout := time.Duration(*timeout) * time.Second
				deadline := time.Now().Add(txTimeout)
				var finalStatus string
				for time.Now().Before(deadline) {
					if ctx.Err() != nil {
						finalStatus = "dropped"
						break
					}
					time.Sleep(500 * time.Millisecond)
					pollCtx, pollCancel := context.WithTimeout(ctx, 5*time.Second)
					status, err := getSignatureStatus(pollCtx, *rpcURL, sig)
					pollCancel()
					if err != nil {
						continue
					}
					if status == "confirmed" {
						finalStatus = "confirmed"
						break
					}
					if status == "failed" {
						finalStatus = "failed"
						break
					}
				}
				if finalStatus == "" {
					finalStatus = "dropped"
				}

				confirmedAt := time.Now()
				latencyMs := confirmedAt.Sub(submittedAt).Milliseconds()

				switch finalStatus {
				case "confirmed":
					atomic.AddInt64(&atomicConfirmed, 1)
				case "failed":
					atomic.AddInt64(&atomicFailed, 1)
				default:
					atomic.AddInt64(&atomicDropped, 1)
				}

				results <- TxResult{
					Signature:   sig,
					SubmittedAt: submittedAt,
					ConfirmedAt: confirmedAt,
					Status:      finalStatus,
					LatencyMs:   latencyMs,
				}
			}
		}(w)
	}

	// Wait for all workers
	go func() {
		wg.Wait()
		close(results)
	}()

	// Collect results
	var allResults []TxResult
	for r := range results {
		allResults = append(allResults, r)
	}

	totalDuration := time.Since(startTime).Seconds()

	// Calculate report
	submitted := int(atomic.LoadInt64(&atomicSubmitted))
	confirmed := int(atomic.LoadInt64(&atomicConfirmed))
	failed := int(atomic.LoadInt64(&atomicFailed))
	dropped := int(atomic.LoadInt64(&atomicDropped))
	timedOut := int(atomic.LoadInt64(&atomicTimedOut))

	var latencies []int64
	for _, r := range allResults {
		if r.Status == "confirmed" {
			latencies = append(latencies, r.LatencyMs)
		}
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	var p50, p90, p99, maxLat int64
	if len(latencies) > 0 {
		p50 = latencies[int(float64(len(latencies))*0.50)]
		p90 = latencies[int(math.Min(float64(len(latencies))*0.90, float64(len(latencies)-1)))]
		p99 = latencies[int(math.Min(float64(len(latencies))*0.99, float64(len(latencies)-1)))]
		maxLat = latencies[len(latencies)-1]
	}

	report := Report{
		TotalSubmitted:         submitted,
		TotalConfirmed:         confirmed,
		TotalFailed:            failed,
		TotalDropped:           dropped,
		TotalTimedOut:          timedOut,
		SubmissionsPerSecond:   float64(submitted) / totalDuration,
		ConfirmationsPerSecond: float64(confirmed) / totalDuration,
		LatencyP50Ms:           p50,
		LatencyP90Ms:           p90,
		LatencyP99Ms:           p99,
		LatencyMaxMs:           maxLat,
		TotalDurationSeconds:   math.Round(totalDuration*100) / 100,
		RpcErrors:              rpcErrors,
		WalletsUsed:            len(fundedWallets),
		Concurrency:            *concurrency,
		RpcEndpoint:            *rpcURL,
	}

	// Print report
	fmt.Println()
	fmt.Println("=== Results ===")
	fmt.Printf("Total submitted:          %d\n", report.TotalSubmitted)
	fmt.Printf("Total confirmed:          %d\n", report.TotalConfirmed)
	fmt.Printf("Total failed:             %d\n", report.TotalFailed)
	fmt.Printf("Total dropped:            %d\n", report.TotalDropped)
	fmt.Printf("Submissions/sec:          %.1f\n", report.SubmissionsPerSecond)
	fmt.Printf("Confirmations/sec:        %.1f\n", report.ConfirmationsPerSecond)
	fmt.Printf("Latency p50:              %dms\n", report.LatencyP50Ms)
	fmt.Printf("Latency p90:              %dms\n", report.LatencyP90Ms)
	fmt.Printf("Latency p99:              %dms\n", report.LatencyP99Ms)
	fmt.Printf("Latency max:              %dms\n", report.LatencyMaxMs)
	fmt.Printf("Total duration:           %.2fs\n", report.TotalDurationSeconds)

	if len(rpcErrors) > 0 {
		fmt.Println("\nRPC Errors:")
		for k, v := range rpcErrors {
			fmt.Printf("  %s: %d\n", k, v)
		}
	}

	// Write JSON
	if *outputPath != "" {
		jsonData, _ := json.MarshalIndent(report, "", "  ")
		if err := os.WriteFile(*outputPath, jsonData, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error writing report: %v\n", err)
		} else {
			fmt.Printf("\nReport written to: %s\n", *outputPath)
		}
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

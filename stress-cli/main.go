package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"os/signal"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/programs/system"
	"github.com/gagliardetto/solana-go/rpc"
)

// ---------------------------------------------------------------------------
// Report — final JSON-serializable output
// ---------------------------------------------------------------------------

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
// TxResult — per-transaction outcome collected from workers
// ---------------------------------------------------------------------------

type TxResult struct {
	SubmittedAt time.Time
	ConfirmedAt time.Time
	Submitted   bool
	Confirmed   bool
	Failed      bool
	Dropped     bool
	TimedOut    bool
	ErrMsg      string
}

// ---------------------------------------------------------------------------
// Job — unit of work sent to a worker via the jobs channel
// ---------------------------------------------------------------------------

type Job struct {
	Sender   solana.PrivateKey
	Receiver solana.PublicKey
}

// ---------------------------------------------------------------------------
// CLI configuration parsed from flags
// ---------------------------------------------------------------------------

type Config struct {
	Wallets       int
	Transactions  int
	Concurrency   int
	TxType        string
	RpcURL        string
	Timeout       int
	AirdropAmount float64
	OutputFile    string
}

func parseFlags() Config {
	cfg := Config{}
	flag.IntVar(&cfg.Wallets, "wallets", 10, "Number of sender wallets to generate")
	flag.IntVar(&cfg.Transactions, "transactions", 1000, "Total transactions to send")
	flag.IntVar(&cfg.Concurrency, "concurrency", 50, "Number of parallel workers")
	flag.StringVar(&cfg.TxType, "type", "sol-transfer", "Transaction type: sol-transfer or spl-transfer")
	flag.StringVar(&cfg.RpcURL, "rpc", "", "Solana RPC endpoint URL (required)")
	flag.IntVar(&cfg.Timeout, "timeout", 30, "Per-transaction timeout in seconds")
	flag.Float64Var(&cfg.AirdropAmount, "airdrop-amount", 10, "SOL to airdrop per wallet")
	flag.StringVar(&cfg.OutputFile, "output", "", "Path to write JSON report (optional)")
	flag.Parse()
	return cfg
}

func validateConfig(cfg Config) error {
	if cfg.RpcURL == "" {
		return fmt.Errorf("--rpc flag is required")
	}
	if cfg.Wallets < 1 {
		return fmt.Errorf("--wallets must be >= 1")
	}
	if cfg.Transactions < 1 {
		return fmt.Errorf("--transactions must be >= 1")
	}
	if cfg.Concurrency < 1 {
		return fmt.Errorf("--concurrency must be >= 1")
	}
	if cfg.TxType != "sol-transfer" && cfg.TxType != "spl-transfer" {
		return fmt.Errorf("--type must be sol-transfer or spl-transfer")
	}
	if cfg.Timeout < 1 {
		return fmt.Errorf("--timeout must be >= 1")
	}
	if cfg.AirdropAmount <= 0 {
		return fmt.Errorf("--airdrop-amount must be > 0")
	}
	return nil
}

// ---------------------------------------------------------------------------
// Wallet generation
// ---------------------------------------------------------------------------

func generateWallets(n int) []solana.PrivateKey {
	wallets := make([]solana.PrivateKey, n)
	for i := 0; i < n; i++ {
		account := solana.NewWallet()
		wallets[i] = account.PrivateKey
	}
	return wallets
}

// ---------------------------------------------------------------------------
// Airdrop phase — parallel airdrops with confirmation polling
// ---------------------------------------------------------------------------

func airdropToWallets(ctx context.Context, client *rpc.Client, wallets []solana.PrivateKey, amountSOL float64) error {
	lamports := uint64(amountSOL * 1_000_000_000)

	fmt.Printf("Airdropping %.1f SOL to %d wallets...\n", amountSOL, len(wallets))

	var wg sync.WaitGroup
	errCh := make(chan error, len(wallets))
	// Limit airdrop concurrency to avoid hammering the RPC.
	sem := make(chan struct{}, 10)

	for i, w := range wallets {
		wg.Add(1)
		go func(idx int, wallet solana.PrivateKey) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			pubkey := wallet.PublicKey()

			reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
			defer cancel()

			sig, err := client.RequestAirdrop(reqCtx, pubkey, lamports, rpc.CommitmentFinalized)
			if err != nil {
				errCh <- fmt.Errorf("airdrop wallet %d (%s): %w", idx, pubkey.String()[:8], err)
				return
			}

			// Poll for confirmation up to 60 seconds.
			if err := waitForSignature(ctx, client, sig, 60*time.Second); err != nil {
				errCh <- fmt.Errorf("airdrop confirmation wallet %d: %w", idx, err)
				return
			}

			fmt.Printf("  Wallet %d/%d funded (%s...)\n", idx+1, len(wallets), pubkey.String()[:8])
		}(i, w)
	}

	wg.Wait()
	close(errCh)

	var errs []error
	for e := range errCh {
		errs = append(errs, e)
	}

	if len(errs) > 0 {
		fmt.Printf("WARNING: %d/%d airdrops failed:\n", len(errs), len(wallets))
		for _, e := range errs {
			fmt.Printf("  - %s\n", e)
		}
		// If all failed, abort. Otherwise continue with wallets that succeeded.
		if len(errs) == len(wallets) {
			return fmt.Errorf("all airdrops failed, cannot proceed")
		}
	}

	fmt.Println("Airdrop phase complete.")
	return nil
}

// waitForSignature polls getSignatureStatuses until the signature is confirmed
// or the timeout elapses.
func waitForSignature(ctx context.Context, client *rpc.Client, sig solana.Signature, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		pollCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		result, err := client.GetSignatureStatuses(pollCtx, true, sig)
		cancel()

		if err == nil && result != nil && result.Value != nil {
			for _, status := range result.Value {
				if status != nil {
					if status.Err != nil {
						return fmt.Errorf("transaction failed: %v", status.Err)
					}
					if status.ConfirmationStatus == rpc.ConfirmationStatusConfirmed ||
						status.ConfirmationStatus == rpc.ConfirmationStatusFinalized {
						return nil
					}
				}
			}
		}

		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("confirmation timeout after %v", timeout)
}

// ---------------------------------------------------------------------------
// Worker — reads jobs, builds & sends transactions, polls for confirmation
// ---------------------------------------------------------------------------

func worker(
	ctx context.Context,
	id int,
	client *rpc.Client,
	jobs <-chan Job,
	results chan<- TxResult,
	txTimeout time.Duration,
	submitted *int64,
	confirmed *int64,
	failed *int64,
	dropped *int64,
	timedOut *int64,
	wg *sync.WaitGroup,
) {
	defer wg.Done()

	var (
		cachedBlockhash solana.Hash
		txCounter       int
	)

	for job := range jobs {
		select {
		case <-ctx.Done():
			// Context cancelled (e.g. SIGINT). Drain remaining jobs silently.
			results <- TxResult{TimedOut: true, ErrMsg: "context cancelled"}
			continue
		default:
		}

		result := TxResult{}

		// Refresh blockhash every 10 transactions per worker.
		if txCounter%10 == 0 {
			bhCtx, bhCancel := context.WithTimeout(ctx, 5*time.Second)
			recent, err := client.GetLatestBlockhash(bhCtx, rpc.CommitmentFinalized)
			bhCancel()
			if err != nil {
				result.Failed = true
				result.ErrMsg = fmt.Sprintf("get blockhash: %s", err.Error())
				atomic.AddInt64(failed, 1)
				results <- result
				txCounter++
				continue
			}
			cachedBlockhash = recent.Value.Blockhash
		}

		// Build SOL transfer transaction (0.001 SOL = 1_000_000 lamports).
		tx, err := solana.NewTransaction(
			[]solana.Instruction{
				system.NewTransferInstruction(
					1_000_000, // 0.001 SOL
					job.Sender.PublicKey(),
					job.Receiver,
				).Build(),
			},
			cachedBlockhash,
			solana.TransactionPayer(job.Sender.PublicKey()),
		)
		if err != nil {
			result.Failed = true
			result.ErrMsg = fmt.Sprintf("build tx: %s", err.Error())
			atomic.AddInt64(failed, 1)
			results <- result
			txCounter++
			continue
		}

		// Sign the transaction.
		_, err = tx.Sign(func(key solana.PublicKey) *solana.PrivateKey {
			if key.Equals(job.Sender.PublicKey()) {
				return &job.Sender
			}
			return nil
		})
		if err != nil {
			result.Failed = true
			result.ErrMsg = fmt.Sprintf("sign tx: %s", err.Error())
			atomic.AddInt64(failed, 1)
			results <- result
			txCounter++
			continue
		}

		// Submit the transaction.
		sendCtx, sendCancel := context.WithTimeout(ctx, 10*time.Second)
		sig, err := client.SendTransaction(sendCtx, tx)
		sendCancel()

		result.SubmittedAt = time.Now()

		if err != nil {
			result.Failed = true
			result.Submitted = false
			result.ErrMsg = fmt.Sprintf("send tx: %s", err.Error())
			atomic.AddInt64(failed, 1)
			results <- result
			txCounter++
			continue
		}

		result.Submitted = true
		atomic.AddInt64(submitted, 1)

		// Poll for confirmation until confirmed or timeout.
		confirmDeadline := time.Now().Add(txTimeout)
		txConfirmed := false
		txFailed := false
		var pollErr string

		for time.Now().Before(confirmDeadline) {
			select {
			case <-ctx.Done():
				break
			default:
			}
			if ctx.Err() != nil {
				break
			}

			pollCtx, pollCancel := context.WithTimeout(ctx, 5*time.Second)
			statuses, err := client.GetSignatureStatuses(pollCtx, true, sig)
			pollCancel()

			if err != nil {
				// Transient RPC error — retry after delay.
				time.Sleep(500 * time.Millisecond)
				continue
			}

			if statuses != nil && statuses.Value != nil && len(statuses.Value) > 0 {
				status := statuses.Value[0]
				if status != nil {
					if status.Err != nil {
						txFailed = true
						pollErr = fmt.Sprintf("tx error: %v", status.Err)
						break
					}
					if status.ConfirmationStatus == rpc.ConfirmationStatusConfirmed ||
						status.ConfirmationStatus == rpc.ConfirmationStatusFinalized {
						txConfirmed = true
						break
					}
				}
			}

			time.Sleep(500 * time.Millisecond)
		}

		result.ConfirmedAt = time.Now()

		if txConfirmed {
			result.Confirmed = true
			atomic.AddInt64(confirmed, 1)
		} else if txFailed {
			result.Failed = true
			result.ErrMsg = pollErr
			atomic.AddInt64(failed, 1)
		} else if ctx.Err() != nil {
			result.TimedOut = true
			result.ErrMsg = "context cancelled"
			atomic.AddInt64(timedOut, 1)
		} else {
			// Deadline exceeded without confirmation — could be dropped or timed out.
			result.Dropped = true
			result.ErrMsg = "confirmation timeout — transaction likely dropped"
			atomic.AddInt64(dropped, 1)
		}

		results <- result
		txCounter++
	}
}

// ---------------------------------------------------------------------------
// Progress printer — runs in its own goroutine
// ---------------------------------------------------------------------------

func progressPrinter(
	ctx context.Context,
	start time.Time,
	submitted, confirmed, failed, dropped, timedOut *int64,
	total int,
	done <-chan struct{},
) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-done:
			return
		case <-ctx.Done():
			return
		case <-ticker.C:
			s := atomic.LoadInt64(submitted)
			c := atomic.LoadInt64(confirmed)
			f := atomic.LoadInt64(failed)
			d := atomic.LoadInt64(dropped)
			t := atomic.LoadInt64(timedOut)
			elapsed := time.Since(start).Seconds()
			inFlight := s - c - f - d - t
			if inFlight < 0 {
				inFlight = 0
			}
			fmt.Printf("[%.1fs] submitted=%d confirmed=%d in-flight=%d failed=%d dropped=%d\n",
				elapsed, s, c, inFlight, f, d)
		}
	}
}

// ---------------------------------------------------------------------------
// Percentile calculation
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Report generation
// ---------------------------------------------------------------------------

func buildReport(results []TxResult, cfg Config, totalDuration time.Duration) Report {
	report := Report{
		RpcErrors:   make(map[string]int),
		WalletsUsed: cfg.Wallets,
		Concurrency: cfg.Concurrency,
		RpcEndpoint: cfg.RpcURL,
	}

	var latencies []int64

	for _, r := range results {
		if r.Submitted {
			report.TotalSubmitted++
		}
		if r.Confirmed {
			report.TotalConfirmed++
			latency := r.ConfirmedAt.Sub(r.SubmittedAt).Milliseconds()
			latencies = append(latencies, latency)
		}
		if r.Failed {
			report.TotalFailed++
			if r.ErrMsg != "" {
				report.RpcErrors[r.ErrMsg]++
			}
		}
		if r.Dropped {
			report.TotalDropped++
		}
		if r.TimedOut {
			report.TotalTimedOut++
		}
	}

	dur := totalDuration.Seconds()
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
	fmt.Println("=============================================================")
	fmt.Println("                    STRESS TEST REPORT")
	fmt.Println("=============================================================")
	fmt.Printf("RPC Endpoint:           %s\n", r.RpcEndpoint)
	fmt.Printf("Wallets Used:           %d\n", r.WalletsUsed)
	fmt.Printf("Concurrency:            %d\n", r.Concurrency)
	fmt.Printf("Total Duration:         %.2fs\n", r.TotalDurationSeconds)
	fmt.Println("-------------------------------------------------------------")
	fmt.Printf("Submitted:              %d\n", r.TotalSubmitted)
	fmt.Printf("Confirmed:              %d\n", r.TotalConfirmed)
	fmt.Printf("Failed:                 %d\n", r.TotalFailed)
	fmt.Printf("Dropped:                %d\n", r.TotalDropped)
	fmt.Printf("Timed Out:              %d\n", r.TotalTimedOut)
	fmt.Println("-------------------------------------------------------------")
	fmt.Printf("Submissions/sec:        %.2f\n", r.SubmissionsPerSecond)
	fmt.Printf("Confirmations/sec:      %.2f\n", r.ConfirmationsPerSecond)
	fmt.Println("-------------------------------------------------------------")
	fmt.Printf("Latency P50:            %d ms\n", r.LatencyP50Ms)
	fmt.Printf("Latency P90:            %d ms\n", r.LatencyP90Ms)
	fmt.Printf("Latency P99:            %d ms\n", r.LatencyP99Ms)
	fmt.Printf("Latency Max:            %d ms\n", r.LatencyMaxMs)

	if len(r.RpcErrors) > 0 {
		fmt.Println("-------------------------------------------------------------")
		fmt.Println("RPC Errors:")
		for msg, count := range r.RpcErrors {
			fmt.Printf("  [%d] %s\n", count, msg)
		}
	}

	fmt.Println("=============================================================")
}

func writeReportJSON(path string, r Report) error {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal report: %w", err)
	}
	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("write report file: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	cfg := parseFlags()

	if err := validateConfig(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		flag.Usage()
		os.Exit(1)
	}

	if cfg.TxType == "spl-transfer" {
		fmt.Fprintln(os.Stderr, "Error: spl-transfer is not yet implemented. Use --type=sol-transfer.")
		os.Exit(1)
	}

	// Top-level context — cancelled on SIGINT/SIGTERM.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	// RPC client.
	client := rpc.New(cfg.RpcURL)

	// -----------------------------------------------------------------------
	// Phase 1: Generate wallets and airdrop
	// -----------------------------------------------------------------------

	fmt.Printf("Generating %d wallets...\n", cfg.Wallets)
	wallets := generateWallets(cfg.Wallets)

	if err := airdropToWallets(ctx, client, wallets, cfg.AirdropAmount); err != nil {
		fmt.Fprintf(os.Stderr, "Fatal: %s\n", err)
		os.Exit(1)
	}

	// -----------------------------------------------------------------------
	// Phase 2: Prepare channels
	// -----------------------------------------------------------------------

	jobs := make(chan Job, cfg.Transactions)
	resultsCh := make(chan TxResult, cfg.Transactions)

	// Atomic counters for live progress.
	var (
		atomicSubmitted int64
		atomicConfirmed int64
		atomicFailed    int64
		atomicDropped   int64
		atomicTimedOut  int64
	)

	// -----------------------------------------------------------------------
	// Phase 3: Start workers
	// -----------------------------------------------------------------------

	txTimeout := time.Duration(cfg.Timeout) * time.Second

	var workerWg sync.WaitGroup
	for i := 0; i < cfg.Concurrency; i++ {
		workerWg.Add(1)
		go worker(
			ctx, i, client, jobs, resultsCh, txTimeout,
			&atomicSubmitted, &atomicConfirmed, &atomicFailed,
			&atomicDropped, &atomicTimedOut,
			&workerWg,
		)
	}

	// -----------------------------------------------------------------------
	// Phase 4: Progress printer
	// -----------------------------------------------------------------------

	startTime := time.Now()
	progressDone := make(chan struct{})
	go progressPrinter(
		ctx, startTime,
		&atomicSubmitted, &atomicConfirmed, &atomicFailed,
		&atomicDropped, &atomicTimedOut,
		cfg.Transactions, progressDone,
	)

	// -----------------------------------------------------------------------
	// Phase 5: Enqueue jobs
	// -----------------------------------------------------------------------

	go func() {
		rng := rand.New(rand.NewSource(time.Now().UnixNano()))
		for i := 0; i < cfg.Transactions; i++ {
			senderIdx := i % len(wallets)
			// Pick a random receiver that is different from the sender.
			receiverIdx := rng.Intn(len(wallets))
			for receiverIdx == senderIdx && len(wallets) > 1 {
				receiverIdx = rng.Intn(len(wallets))
			}

			select {
			case jobs <- Job{
				Sender:   wallets[senderIdx],
				Receiver: wallets[receiverIdx].PublicKey(),
			}:
			case <-ctx.Done():
				break
			}
		}
		close(jobs)
	}()

	// -----------------------------------------------------------------------
	// Phase 6: Collect results — also handle SIGINT
	// -----------------------------------------------------------------------

	allResults := make([]TxResult, 0, cfg.Transactions)
	collected := 0

	// Close resultsCh once all workers finish.
	go func() {
		workerWg.Wait()
		close(resultsCh)
	}()

	interrupted := false

collectLoop:
	for {
		select {
		case r, ok := <-resultsCh:
			if !ok {
				// All workers finished.
				break collectLoop
			}
			allResults = append(allResults, r)
			collected++
		case sig := <-sigCh:
			fmt.Printf("\nReceived %s — shutting down gracefully...\n", sig)
			interrupted = true
			cancel() // Cancel context to stop workers.
			// Drain remaining results with a short deadline.
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

	// -----------------------------------------------------------------------
	// Phase 7: Build and output report
	// -----------------------------------------------------------------------

	report := buildReport(allResults, cfg, totalDuration)

	if interrupted {
		fmt.Println("\n*** PARTIAL REPORT (interrupted) ***")
	}

	printReport(report)

	if cfg.OutputFile != "" {
		if err := writeReportJSON(cfg.OutputFile, report); err != nil {
			fmt.Fprintf(os.Stderr, "Error writing report: %s\n", err)
			os.Exit(1)
		}
		fmt.Printf("\nJSON report written to: %s\n", cfg.OutputFile)
	}

	if interrupted {
		os.Exit(130) // Standard exit code for SIGINT.
	}
}

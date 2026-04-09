package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"testing"
	"time"
)

func mockRPCHandler(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var req struct {
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	json.Unmarshal(body, &req)

	w.Header().Set("Content-Type", "application/json")

	switch req.Method {
	case "getLatestBlockhash":
		fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":{"value":{"blockhash":"4sGjMW1sUnHzSxGspuhSqgenEhWGe77V6JGzWjSodFAy","lastValidBlockHeight":1000}}}`)
	case "requestAirdrop":
		fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":"5VERFwkMApgmjmXZBf1J2aXmZMg9nMk4X8fPxcCwNJg2eA4fGQnVqBTWnV9PBbfxKq5k9mXhVdhxMpGsMwfcwZo"}`)
	case "sendTransaction":
		fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":"2jg7WjZpZn6JkPPf2K56cRPxyqbJVPT9jSZvhQGzL7b3TjfGgLFeRSzCq4CZVM68mGzq5JwoGUxJsZ9d3M4yD9YS"}`)
	case "getSignatureStatuses":
		fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmationStatus":"confirmed","err":null}]}}`)
	default:
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found: %s"}}`, req.Method)
	}
}

func TestMockBasic(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(mockRPCHandler))
	defer server.Close()

	// Build binary
	cmd := exec.Command("go", "build", "-o", "/tmp/stress-cli-test", ".")
	cmd.Dir = "."
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build failed: %s %v", string(out), err)
	}

	// Run with small numbers
	runCmd := exec.Command("/tmp/stress-cli-test",
		"--rpc", server.URL,
		"--wallets", "3",
		"--transactions", "10",
		"--concurrency", "5",
		"--output", "/tmp/stress-test-report.json",
		"--timeout", "5",
	)
	runCmd.Stdout = os.Stdout
	runCmd.Stderr = os.Stderr

	done := make(chan error, 1)
	go func() { done <- runCmd.Run() }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("stress-cli failed: %v", err)
		}
	case <-time.After(30 * time.Second):
		runCmd.Process.Kill()
		t.Fatal("stress-cli timed out (deadlock?)")
	}

	// Verify JSON report
	data, err := os.ReadFile("/tmp/stress-test-report.json")
	if err != nil {
		t.Fatalf("report not created: %v", err)
	}
	var report Report
	if err := json.Unmarshal(data, &report); err != nil {
		t.Fatalf("bad report JSON: %v", err)
	}
	if report.TotalSubmitted == 0 {
		t.Fatal("no transactions submitted")
	}
	if report.TotalConfirmed == 0 {
		t.Fatal("no transactions confirmed")
	}
	t.Logf("Report: submitted=%d confirmed=%d p50=%dms", report.TotalSubmitted, report.TotalConfirmed, report.LatencyP50Ms)
}

func TestMockHighConcurrency(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(mockRPCHandler))
	defer server.Close()

	runCmd := exec.Command("/tmp/stress-cli-test",
		"--rpc", server.URL,
		"--wallets", "20",
		"--transactions", "200",
		"--concurrency", "200",
		"--timeout", "5",
	)
	runCmd.Stdout = os.Stdout
	runCmd.Stderr = os.Stderr

	done := make(chan error, 1)
	go func() { done <- runCmd.Run() }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("200 concurrent failed: %v", err)
		}
	case <-time.After(60 * time.Second):
		runCmd.Process.Kill()
		t.Fatal("deadlock with 200 concurrent workers")
	}
	t.Log("200 concurrent workers: PASSED — no panic, no deadlock")
}

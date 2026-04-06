module github.com/solana-cluster/stress-cli

go 1.21

require (
	github.com/gagliardetto/solana-go v1.10.0
)

// NOTE: Run `go mod tidy` to populate indirect dependencies and generate go.sum.
// The solana-go library pulls in many transitive dependencies that will be
// resolved automatically by the Go toolchain.

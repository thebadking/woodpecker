#!/bin/bash

echo "Building Woodpecker binaries for multiple architectures..."

# Build UI first (required for embedding web assets)
echo "Building UI assets..."
(cd web/; pnpm install --frozen-lockfile; pnpm build)

# Create dist directory
mkdir -p dist

# Build for AMD64
echo "Building AMD64 binaries..."
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dist/woodpecker-server-amd64 ./cmd/server
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dist/woodpecker-agent-amd64 ./cmd/agent

# Build for ARM64 (Raspberry Pi)
echo "Building ARM64 binaries..."
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o dist/woodpecker-server-arm64 ./cmd/server
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o dist/woodpecker-agent-arm64 ./cmd/agent

# Build test program for local testing
echo "Building gRPC proxy test..."
go build -o test-http-proxy test-http-proxy-simple.go

echo "Built binaries:"
ls -la dist/woodpecker-*-amd64 dist/woodpecker-*-arm64 test-http-proxy

echo ""
echo "Usage:"
echo "  Local testing (AMD64):"
echo "    ./dist/woodpecker-server-amd64 [options]"
echo "    ./dist/woodpecker-agent-amd64 [options]"
echo "    ./test-http-proxy"
echo ""
echo "  Raspberry Pi (ARM64):"
echo "    scp dist/woodpecker-*-arm64 pi@your-pi-ip:/path/to/destination/"
echo "    ssh pi@your-pi-ip './woodpecker-server-arm64 [options]'"

echo ""
echo "Test the gRPC proxy locally:"
./test-http-proxy

echo ""
echo "Cleaning up test binary..."
rm -f test-http-proxy

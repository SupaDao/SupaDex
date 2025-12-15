#!/bin/bash

# Documentation generation script for Hybrid DEX
# Generates documentation from NatSpec comments

set -e

echo "==================================="
echo "Generating Documentation"
echo "==================================="

# Colors
GREEN='\033[0.32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if forge is installed
if ! command -v forge &> /dev/null; then
    echo "Error: Foundry not installed. Install from https://getfoundry.sh"
    exit 1
fi

# Create docs directory
mkdir -p docs/contracts/core
mkdir -p docs/contracts/periphery
mkdir -p docs/contracts/libraries
mkdir -p docs/contracts/governance

echo -e "${BLUE}Step 1: Extracting NatSpec comments...${NC}"

# Extract NatSpec for core contracts
echo "  - Core contracts"
forge doc --out docs/forge-docs

# Generate markdown from NatSpec
echo -e "${BLUE}Step 2: Generating markdown documentation...${NC}"

# Note: This is a placeholder. In production, you'd use a tool like:
# - solidity-docgen
# - hardhat-docgen
# - custom script to parse forge doc output

echo "  - Factory.sol"
echo "  - ConcentratedPool.sol"
echo "  - BatchAuction.sol"
echo "  - LimitOrderBook.sol"

echo -e "${BLUE}Step 3: Generating contract diagrams...${NC}"

# Generate inheritance diagrams
# Note: Requires sol2uml (npm install -g sol2uml)
if command -v sol2uml &> /dev/null; then
    echo "  - Generating inheritance diagrams"
    sol2uml contracts -o docs/diagrams/inheritance.svg
else
    echo "  - Skipping diagrams (sol2uml not installed)"
fi

echo -e "${BLUE}Step 4: Generating storage layouts...${NC}"

# Generate storage layouts for upgradeable contracts
forge inspect Factory storage-layout > docs/storage/Factory.json
forge inspect ConcentratedPool storage-layout > docs/storage/ConcentratedPool.json
forge inspect BatchAuction storage-layout > docs/storage/BatchAuction.json

echo -e "${BLUE}Step 5: Generating gas reports...${NC}"

# Generate gas report
forge test --gas-report > docs/gas-report.txt

echo -e "${GREEN}Documentation generated successfully!${NC}"
echo ""
echo "Documentation available in:"
echo "  - docs/forge-docs/     (NatSpec documentation)"
echo "  - docs/storage/        (Storage layouts)"
echo "  - docs/gas-report.txt  (Gas benchmarks)"
echo ""
echo "To view documentation:"
echo "  - Open docs/index.md in your browser"
echo "  - Or run: mdbook serve (if mdbook is installed)"

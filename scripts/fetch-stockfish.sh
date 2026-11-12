#!/usr/bin/env bash
# Puts an arm64 Stockfish 19 into Vendor/stockfish/ (gitignored): from Homebrew if installed, else `brew install stockfish`.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor/stockfish
command -v stockfish >/dev/null || brew install stockfish
SRC="$(brew --prefix stockfish)/bin/stockfish"
lipo -archs "$SRC" | grep -q arm64
ditto "$SRC" Vendor/stockfish/stockfish
echo "Vendor/stockfish/stockfish: $("Vendor/stockfish/stockfish" <<<'quit' | head -1)"

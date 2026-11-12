#!/usr/bin/env bash
# Copies an arm64 Stockfish binary into the app bundle (Contents/MacOS/stockfish). Source order:
# Vendor/stockfish/stockfish (scripts/fetch-stockfish.sh) → Homebrew's stockfish. Without one, the app still runs
# and uses its built-in fallback engine.
set -euo pipefail
DEST="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/stockfish"
for SRC in "$SRCROOT/Vendor/stockfish/stockfish" "/opt/homebrew/opt/stockfish/bin/stockfish"; do
  if [[ -x "$SRC" ]]; then
    if [[ ! -f "$DEST" || "$SRC" -nt "$DEST" ]]; then
      ditto "$SRC" "$DEST"
      chmod 755 "$DEST"
    fi
    exit 0
  fi
done
echo "note: no Stockfish binary found; GTNW Chess will use its built-in engine" >&2

# Changelog

## Unreleased

- **CI:** GitHub Actions builds and tests on `macos-15` for every push and pull request to `main`, with Stockfish
  from Homebrew so the engine integration tests run.
- **Saves are migrated, never thrown away.** The save format is now 2 (adds `writtenBy`, the app version that wrote
  it). Format 1 saves from 1.0 and 1.1 are migrated forward. A save from a newer build is refused, and a damaged save
  is rejected; either way the file is moved aside to `current-game.unreadable-<date>.json` and an alert says where.
  Before, any version mismatch was silently ignored and then overwritten by the next autosave. Note: 1.1.0 and
  earlier cannot read format 2 and will still overwrite it.
- **Hardened runtime on**, with no entitlements. Stockfish still runs as a subprocess. `--selftest` now also gets a
  legal move from the bundled Stockfish.
- **`tools/release.sh`:** archive, export and bundle checks (Stockfish SHA-256 against `scripts/stockfish.sha256`,
  licence files, no certificates, keys or credentials), ad hoc or `--notarize` (Developer ID + notarization, off by
  default), and a DMG copied to both binaries folders. `--dry-run` does all of it in a temp folder and copies
  nothing. Releases leave out the Nova Games CA certificates, and a build without them no longer offers the Nova Games
  sign-in.
- **Remappable keys (Settings › Keys)** for Hint, Undo Move, Flip Board, Toggle 2D / 3D, Reset Camera and Skip
  Battle. They are stored in UserDefaults through the existing preference registration, and the defaults are the
  1.1 keys. Duplicates and fixed menu shortcuts are refused, and Reset to Defaults restores the 1.1 keys.

## 1.1.0 (2026-11-12)

- **Watch: AI vs AI.** Each side is Nova's engine (8 levels) or a language model (backend + model from NovaAIKit's
  picker), so you can watch model vs model or engine vs model. Every side defaults to the engine. The spectator bar
  shows the matchup and has pause, pace and take over. Take over hands you the side to move, and the other side keeps
  its engine or model.
- **Model moves:** the model gets the FEN, the legal moves (SAN) and the recent moves. Its reply is checked by one
  validator. An invalid reply is re-asked up to 2 times with the error, and after that Nova's engine plays the move.
- **Recording:** watch games are recorded as `AI vs AI` with `spectator`, `matchup` (kind `model` with backend, model
  and label) and `fallbacks`. Each model answer is a `model_reply` event (side, backend, model, excerpt, latency,
  valid, fallback).
- **NovaAIKit 1.1.0:** adds the Anthropic, Gemini, xAI, Mistral, DeepSeek and Meta Llama API backends,
  per-request overrides, and the **Allow Nova** switch in Settings › AI so the app can run with no Nova dependency.
- **Ideas adopted from id Software's released source (no code copied):**
  - A seeded gameplay RNG (SplitMix64) kept apart from the cosmetic RNG, with the seed recorded per game.
  - The record as the source of truth for model replies.
  - One validator for every move driver.
  - A per-level personality table as bundled JSON, feeding the built-in engine and the prompts.
  - A chat gate (event + probability + cooldown + situation) for banter and the auto coach.
- **Tests:** new unit, security, performance, retry, integration, functional and UI-state tests for all of the above.

## 1.0.1

- Carnage dial for capture battles.

## 1.0.0

- First release: animated-battle chess for macOS.

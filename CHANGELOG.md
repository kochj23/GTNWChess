# Changelog

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

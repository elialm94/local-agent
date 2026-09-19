# Pair — a voice-first AI pair programmer for macOS

Point at something on your screen, hold **⌥ Space**, talk. Pair sees the UI
element under your pointer, discusses it with you through Grok Voice, and when
you say **"do it"** hands a precise task to **Cursor**, which edits your local
project so your dev server hot-reloads. Say **"undo that"** and the change is
gone — without touching any of your own uncommitted work.

It is not dictation for Cursor. It is a persistent colleague who sees what you
see and uses Cursor as its hands.

```
POINT → TALK → REASON TOGETHER → "DO IT" → SEE RESULT → ("UNDO THAT")
```

Read [ARCHITECTURE.md](ARCHITECTURE.md) for the design. This file is about
running it.

---

## Status — what works today

**Milestone 1 (magic loop) is implemented end to end.** The core loop is
exercised headlessly on Linux by 50 XCTest cases and the `pair-cli` harness
(real git checkpoints, real NDJSON parsing against a fake `agent`, mocked
models). The macOS app wires that core to the real system APIs.

| Layer | State |
|---|---|
| Menu-bar app, floating orb, target outline, debug panel, settings | implemented (`Sources/PairApp`) |
| Global ⌥Space hold / ⌥Space+click / ⌥Space+drag / Esc via `CGEventTap` | implemented |
| Accessibility element under pointer, front app/window, browser URL, DOM id/classes | implemented |
| ScreenCaptureKit crop of the target rect (only on request) | implemented |
| Mic → 24 kHz PCM16 → Grok; Grok PCM16 → speaker; barge-in flush | implemented |
| Project detection: explicit pick, `lsof` on the localhost port, editor window title | implemented |
| Intent routing, execution gate, proposals memory ("do the second one") | implemented + tested |
| Task compiler (Project / Target / Source / Requested change / Constraints / Verification) | implemented + tested |
| Git checkpoint + undo/redo that never touches HEAD, index, or unrelated WIP | implemented + tested |
| Visual verification (before/after crop pixel diff fed back to Grok) | implemented, lightweight |
| Grok Voice realtime WebSocket provider (audio, transcripts, function calling) | implemented against the documented protocol; **not yet exercised against the live service from this environment** |
| Jev fast-decision provider (`POST /v1/systemone`) | implemented against the documented protocol; same caveat |
| Cursor CLI local agent (`agent -p --output-format stream-json`) | implemented; parser tested against a fixture |
| Cursor Cloud agent (`api.cursor.com/v1/agents`) | implemented; optional, needs `CURSOR_API_KEY` |
| Dev bridge (Vite plugin: hovered element → `file:line:component`) | implemented + tested (Node + Swift) |
| Multiple simultaneous agents, A/B variants, Jev-ranked candidates | architecture in place, not built (Milestones 3–4) |

> The macOS target could not be compiled in the Linux environment this was
> written in. The AppKit/AX/ScreenCaptureKit/AVFoundation code was written
> carefully against the current SDK, but expect to fix a handful of compile
> errors on first `swift build` on a Mac. `PairCore` (all the logic) builds and
> tests clean on both platforms.

---

## Run it

### Requirements

- macOS 14 Sonoma or later, Apple Silicon or Intel
- Xcode 15.3+ or the Swift 5.9+ toolchain (`xcode-select --install` is enough for SwiftPM)
- `git` (for checkpoints — the project you edit must be a git repository)
- Cursor CLI for real edits: `curl https://cursor.com/install -fsS | bash`, then `agent login`
- An xAI API key for voice (without one, Pair runs with a text-only mock model)

### Build & launch

```bash
git clone <this repo> pair && cd pair
scripts/make-app.sh            # builds and wraps the binary in build/Pair.app, ad-hoc signed
open build/Pair.app
```

Why the bundle: macOS grants Accessibility / Screen Recording / Microphone to a
*code identity*. `swift run Pair` works too, but every rebuild is a new identity
and you would re-grant permissions each time. The script signs with a stable
identifier (`dev.pair.app`) so permissions stick.

### First launch

1. A waveform icon appears in the menu bar. The Settings window opens because
   permissions are missing.
2. Grant permissions (System Settings → Privacy & Security):
   - **Accessibility** — required. Global shortcut and reading the UI element under the pointer.
   - **Microphone** — required for voice. (Text input in the panel works without it.)
   - **Screen Recording** — optional. Enables small crops of the target for visual questions. Nothing is captured unless a crop is requested during a turn.
   Restart Pair after granting Accessibility (macOS only applies it to new processes).
3. Paste your **xAI API key** (and optionally TypeSafe / Cursor keys) in Settings → *Save & restart assistant*. Keys go to the macOS Keychain (`com.pair.assistant`), never to disk.
4. Menu bar → **Project → Choose Folder…** and pick the git repo of the app you are working on. Pair also detects the project automatically from the `localhost:<port>` in your browser (via `lsof` → dev-server cwd) and from Cursor/VS Code window titles, but an explicit pick is the fastest path and is remembered.
5. Start your app's dev server and open it in Chrome/Safari/Arc.

### The loop

| You | Pair |
|---|---|
| Hover a button, **hold ⌥ Space**, say *"make this button red"* | Orb turns blue, a dashed outline shows what "this" resolves to. On release the utterance + compact screen context go to Grok. Grok records a proposal and confirms in a sentence. |
| Not the right element? **⌥ Space + click** it | Solid outline; confidence 0.95. **⌥ Space + drag** selects a region instead. |
| *"Do it"* | Checkpoint → task compiled → Cursor `agent` starts in your project. Orb goes orange: "Cursor: Make the Send Offer button red". Grok says "On it." and stays in the conversation. |
| Dev server hot-reloads | Pair compares a before/after crop of the target (if screen permission) and tells Grok whether the pixels changed. Orb goes green: "done — 1 file". |
| *"Undo that"* | Files touched by that action are restored from the checkpoint. Your own unstaged edits elsewhere are untouched. *"Redo"* re-applies. *"Go back two changes"* works. |
| **Esc** | Cancels the current turn / stops Grok talking. |
| Menu → **Show Panel** (⌘D) | Transcript, current target and candidates, intent decision, actions, the exact context sent to Grok, tool calls, the Cursor prompt, permissions, per-stage latencies, logs — and a text box that goes through the same pipeline as voice. |

Pair never edits code from casual discussion. Only an explicit imperative in
the current utterance ("do it", "try it", "build it", "change it", "go ahead",
"ship it"…) opens the execution window, and only for a trusted project.

### Headless harness (works on macOS and Linux)

```bash
swift test                                   # 50 tests: routing, gate, attention, compiler, checkpoints, providers, coordinator
swift run pair-cli --project ~/code/myapp --target-dom-id send-offer \
  --say "make this button red" --say "do it" --say "undo that"
swift run pair-cli --project ~/code/myapp -i # interactive; add --agent cursor to use the real CLI
```

The CLI prints every state change, tool call, the compiled Cursor prompt, and a
latency table. With `--voice grok` and `XAI_API_KEY` set it talks to the real
Grok session in text mode; with `--agent cursor` and the CLI installed it makes
real edits (and undoes them).

### Optional: source mapping for your web app

Generic apps get source mapping via `git grep` for the label / DOM id (unique
hit → high confidence). For React/Vite projects you can make it exact:

```js
// vite.config.js
import aiPair from "../pair/devtools/vite-plugin-ai-pair/src/index.js"; // or publish/npm-link it
export default defineConfig({ plugins: [react(), aiPair()] });
```

Dev-server only. It injects a tiny runtime that, on hover, finds the element's
source (hand-written `data-ai-source/-line/-component` attributes → React dev
fiber `_debugSource` → the plugin's own conservative JSX annotation for React
19) and mirrors `file:line:component` onto the hovered element as one class
name. Chromium exposes class names through Accessibility, so the Mac app reads
it with zero network plumbing and the Cursor task gets `src/…/X.tsx:84`. See
`devtools/vite-plugin-ai-pair/src/runtime.js`.

---

## Configuration

| Setting | Where | Notes |
|---|---|---|
| xAI API key (Grok Voice) | Settings window → Keychain; or env `XAI_API_KEY` | Without it: `mock-grok` (text only, deterministic) |
| TypeSafe API key (Jev) | Settings → Keychain; or env `TYPESAFE_API_KEY` | Without it: `mock-jev`; the deterministic router still handles most turns |
| Cursor API key (cloud agents) | Settings → Keychain; or env `CURSOR_API_KEY` | Optional. Local `agent` is preferred for UI edits |
| Cursor CLI path | Settings | Blank = search `PATH` and `~/.local/bin` for `agent` / `cursor-agent` |
| Project | Menu bar → Project | Explicit pick overrides detection; recent picks are remembered |
| Shortcut | `GlobalHotkey.Config` (⌥ Space) | Not yet exposed in Settings |

Env vars override Keychain values (handy for `swift run`). Nothing is written to
plaintext config.

## Integrations: real vs mocked

| Integration | Implementation | Verified how |
|---|---|---|
| **Grok Voice** | `GrokVoiceProvider` — `wss://api.x.ai/v1/realtime`, session.update with instructions/voice/tools, `input_audio_buffer.append/commit`, `response.create`, transcripts, `response.function_call_arguments.done` → tool → `conversation.item.create(function_call_output)`, barge-in via `response.cancel`. Strictly ordered outbox. | Event codec unit-tested; live WebSocket **not** reachable from this environment. Endpoint/event names follow xAI's realtime docs as of Sept 2026 — if the service differs, the codec is one file. |
| **Jev** | `JevProvider` — `POST https://api.typesafe.ai/v1/systemone` with typed `noul`/`choice`/`score` questions | Request/response codec tested against documented shapes; live call not exercised here. |
| **Cursor local** | `CursorCLIAgentProvider` — spawns `agent -p --force --trust --workspace <root> --output-format stream-json [--resume <chatId>] "<prompt>"`, parses NDJSON (`system/init`, `assistant`, `tool_call` read/write, `result`), tracks changed files, resumes sessions for follow-ups | Tested against `Tests/PairCoreTests/Fixtures/fake-agent.sh`, which emits the documented event stream and really edits a file. |
| **Cursor cloud** | `CursorCloudAgentProvider` — `POST /v1/agents`, `GET /v1/agents/{id}`, `POST /v1/agents/{id}/runs/{runId}/cancel` (API key as basic-auth username). Works on a remote clone. | Codec only. |
| **macOS Accessibility / ScreenCaptureKit / AVFoundation / CGEventTap / Keychain** | Real (`Sources/PairApp`) | Written against current SDKs; needs a Mac to compile and exercise. |
| **Mocks** | `MockVoiceProvider` (deterministic: proposes on modify intents, executes on "do it", undoes), `MockFastDecisionProvider`, `MockCodingAgentProvider` (really edits the file so undo is exercised), `SyntheticPerceptionProvider` | Used by tests and `pair-cli`. |

## Known limitations

- **Unverified on a Mac.** The PairApp target was written blind; budget for a short compile-fix pass. Coordinate conversions (AX top-left vs AppKit bottom-left) are handled centrally in `MacPerceptionProvider.flipY` and `HighlightWindow.draw`, which is the first place to look if outlines land in the wrong place, especially on multi-monitor setups (V1 uses the primary screen's frame).
- **Push-to-talk only.** Server VAD is supported by the provider (`serverVAD`) but the hotkey bounds each turn so no audio is streamed while you are not holding it. Interruptions: Esc or start talking during a new hold.
- **Grok does the summarising.** The task compiler structures constraints and verification deterministically; the "requested change" text comes from Grok's `propose_change` summary (or the raw utterance if the model skipped the tool). Quality of the Cursor task tracks the quality of that sentence.
- **Cursor startup latency** is the long pole (seconds). We stream its progress to the orb but cannot make it faster.
- **Source mapping without the dev bridge** relies on `git grep` for the visible label / DOM id — good when unique, low-confidence when not; the prompt tells Cursor to verify.
- **Project detection** is conservative by design: if signals disagree, Pair says so rather than guessing. Pick the project explicitly.
- **Undo granularity** is per action ("keep the CSS but undo the logic" is not supported; that needs per-hunk restore).
- **No OCR, no DOM access in the browser** except via the dev bridge; Safari exposes fewer AX attributes than Chromium.
- **Destructive / deploy / DB / push** levels exist in the permission model but no tool can reach them in V1.
- Single primary display assumed for overlay geometry.

## Next highest-value step

**Compile and run PairApp on a Mac and close the loop with the live services.**
Concretely, in order:

1. `scripts/make-app.sh` on macOS; fix any SDK mismatches (expected: minor).
2. Hold ⌥ Space over a real Chrome button and confirm the outline lands on the right element (the debug panel's Target tab shows the candidates).
3. With `XAI_API_KEY`, confirm the Grok realtime handshake and first-audio latency; adjust event names in `RealtimeEvents.swift` if xAI's API has drifted.
4. With Cursor CLI installed, run the full "make this red → do it → undo that" loop on a Vite app with the dev bridge enabled.

After that, Milestone 2 work is mostly prompt/UX iteration on top of what exists
(proposal memory, interruptions and screen-aware questions are already wired),
and Milestone 3 is turning on Jev-ranked candidates when the AX resolver
returns more than one plausible target.

## Layout

```
Sources/PairCore/      platform-independent engine (builds on Linux; 50 tests)
Sources/PairApp/       macOS app: menu bar, overlays, perception, audio, hotkey, settings
Sources/PairCLI/       headless harness
Tests/PairCoreTests/   XCTest suite + fake-agent fixture
devtools/vite-plugin-ai-pair/   optional dev-bridge for web projects (node --test)
scripts/make-app.sh    .app bundle + ad-hoc signing
ARCHITECTURE.md        components, data flow, schemas, security & latency strategy
```

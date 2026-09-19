# Pair — architecture

A macOS-native, voice-first pair programmer. You point, you talk, you reason
together, you say "do it", Cursor edits the project, you see the result, you
can say "undo that". This document is the map; the code is the territory.

## Components

```
┌──────────────────────── macOS process: Pair.app (Swift) ─────────────────────────┐
│                                                                                  │
│  PairApp (AppKit/SwiftUI, @MainActor)                                            │
│   ├─ GlobalHotkey          CGEventTap: ⌥Space hold / click / drag / Esc          │
│   ├─ MacPerceptionProvider AX element under pointer, front app/window, URL,      │
│   │                        ScreenCaptureKit crops (on demand only)              │
│   ├─ AudioEngine           mic → 24 kHz PCM16 ; PCM16 → speaker                  │
│   ├─ MacProjectDetector    lsof(port)→cwd, editor titles, explicit selection      │
│   ├─ KeychainStore         xAI / TypeSafe / Cursor credentials                   │
│   └─ UI: OrbPanel, HighlightWindow, DebugPanelView, SettingsView, menu bar       │
│                                   │ events / callbacks                          │
│  PairCore (Foundation only; also builds + tests on Linux)                        │
│   ├─ AssistantCoordinator  serial work queue; owns the interaction loop          │
│   ├─ Attention             AttentionResolver (candidates → chosen target)        │
│   ├─ Routing               IntentRouter (deterministic) → ReflexLayer (Jev)      │
│   │                        ExecutionGate (permission model)                      │
│   ├─ Session               SessionMemory (transcript, proposals, actions),       │
│   │                        ContextBuilder (compact [screen context] notes)       │
│   ├─ TaskCompiler          conversation + target + source → AgentTask prompt     │
│   ├─ Checkpoint            GitCheckpointManager (tree snapshots), ActionUndo     │
│   ├─ Tools                 ToolCatalog (typed schemas + permission per tool)     │
│   ├─ Project               ProjectDetection, SourceResolver chain               │
│   └─ Providers             Grok (realtime WS), Jev (HTTP), Cursor CLI (Process), │
│                            Cursor Cloud (HTTP), mocks                            │
└──────────────────────────────────────────────────────────────────────────────────┘
        │ wss                    │ https                 │ child process / https
   xAI Grok Voice           TypeSafe Jev            Cursor `agent` CLI / Cloud Agents API
```

Optional, in the user's web project: `devtools/vite-plugin-ai-pair` (dev-only
runtime that mirrors `file:line:component` for the hovered element into its
class list, which Chromium exposes through Accessibility).

## Data flow — one turn

```
⌥Space down ──► Coordinator.hotkeyDown
                 ├─ voice.beginUserTurn()            (Grok: clear input buffer)
                 ├─ perception.target(at: pointer)   (AX, ~1–5 ms)
                 └─ state = listening ; orb shows ; hover target outlined (dashed)
mic PCM16 ─────► voice.appendAudio  (bypasses the work queue; never waits on state)
⌥Space+click ──► explicitClick → target confidence 0.95, solid outline
⌥Space up ─────► hotkeyUp
                 ├─ refreshProject()  (cached; lsof/git only when signals change)
                 ├─ re-resolve hover target if no explicit one
                 ├─ ContextBuilder → "[screen context] {app, window, url, target,
                 │                     project, proposals, recent actions}"
                 └─ voice.endUserTurn(context)       (Grok: commit + response.create)
Grok ──────────► transcript → IntentRouter.route (deterministic, µs)
                 │            └─ ReflexLayer asks Jev only when the router is unsure
                 │               or the utterance needs target disambiguation
                 ├─ ExecutionGate.observeUserUtterance ("do it" → execution window)
                 ├─ audio deltas → AudioEngine.play ; captions → orb
                 └─ tool calls → AssistantCoordinator+Tools.executeTool
                      ├─ permission check (ToolCatalog level × ExecutionGate)
                      ├─ propose_change   → SessionMemory (numbered, per turn)
                      ├─ execute_change   → TaskCompiler → checkpoint → Cursor agent
                      │     agent events → CodeAction updates → orb "Cursor: <title>"
                      │     finished → changed files (agent-reported or diff-inferred)
                      │              → optional before/after crop comparison
                      │              → note back to Grok ("done; 1 file; pixels changed")
                      └─ undo_last_change → ActionUndoManager.restore(checkpoint)
```

## Process boundaries

| Boundary | Transport | Trust |
|---|---|---|
| PairApp ↔ PairCore | in-process, serial `DispatchQueue` + `@Sendable` callbacks | same process |
| PairCore ↔ Grok Voice | WebSocket `wss://api.x.ai/v1/realtime` | remote; receives *compact context only* |
| PairCore ↔ Jev | HTTPS `POST /v1/systemone` | remote; receives small typed state |
| PairCore ↔ Cursor CLI | child process `agent -p --output-format stream-json`, NDJSON on stdout | local; edits the working tree |
| PairCore ↔ Cursor Cloud | HTTPS `api.cursor.com/v1/agents` | remote; works on a clone, not your tree |
| Browser ↔ Pair | none. The dev bridge writes a class name; Pair reads it via AX | local |

There is no daemon and no local HTTP server in V1.

## Security model

- **Permission levels** (`PermissionLevel`): `read < analyze < discuss <
  localReversibleEdit < destructive < deployment < databaseModification <
  mergeOrPush`. Every tool in `ToolCatalog` declares one.
- **ExecutionGate**: `read/analyze/discuss` are automatic.
  `localReversibleEdit` requires (a) an explicit execution command in the
  *current* utterance window ("do it", "try it", "build it", "change it", "go
  ahead"…, see `IntentRouter.isExecutionCommand`) and (b) a trusted project
  (confidence ≥ 0.6 or explicitly selected). Undo/redo require an undo/redo
  imperative but not a trusted project (they restore state the user already
  saw). Everything `destructive` and above is denied in V1 — no tool exposes it.
- **Checkpoints before every edit**: `GitCheckpointManager` snapshots the
  working tree (including untracked files, excluding ignored) into a dangling
  commit using a *temporary index*. HEAD, branch and the user's index are never
  touched. Undo restores only files changed by the action (agent-reported, or
  inferred by diffing the tree) so unrelated in-progress work survives.
- **Secrets**: Keychain only (`com.pair.assistant`). Env vars override for dev.
  `Redactor` strips API-key-shaped strings, bearer tokens, `.env` lines and
  emails from anything that leaves the machine (context notes, tool results,
  agent prompts).
- **Screen data**: default context is structured (role, label, DOM id, classes,
  ancestor path, bounds). A crop is captured only when Grok calls
  `capture_target/region` or the reflex layer says visual reasoning is needed,
  and only of the target rect. Full-screen capture is not implemented.
- **Cursor CLI** runs with `--force --trust` inside the *selected project only*;
  the checkpoint is the safety net. Cloud agents never touch the local tree.

## Model responsibilities

| | Grok Voice (`VoiceReasoningProvider`) | Jev (`FastDecisionProvider`) | Deterministic code |
|---|---|---|---|
| Conversation, reasoning, UI/UX opinions | ✔ | | |
| Deciding which tool to call | ✔ (function calling) | | gate enforces |
| Remembering proposals ("do the second one") | ✔ (+ SessionMemory mirrors them) | | ordinal parsing |
| Intent classification | | ✔ when router confidence < 0.7 | `IntentRouter` first |
| Target disambiguation among AX candidates | | ✔ when > 1 plausible | `AttentionResolver` scoring |
| Needs screenshot? | | ✔ | keyword heuristics first |
| Execution command detection | | | ✔ only (never a model) |
| Task compilation | ✔ supplies `requested_change` text | | `TaskCompiler` structures it |

Rule: if local logic can answer, no model is called. Jev is never on the
critical path of audio.

## Provider interfaces (`Sources/PairCore/Providers/Protocols.swift`)

```swift
protocol VoiceReasoningProvider: AnyObject {
  var delegate: VoiceProviderDelegate? { get set }
  func connect(config: VoiceSessionConfig) async throws
  func disconnect()
  func beginUserTurn(); func appendAudio(_ pcm16: Data); func endUserTurn(context: String?)
  func sendUserText(_ text: String, context: String?)
  func sendToolResult(callID: String, outputJSON: String)
  func injectSystemNote(_ text: String, requestResponse: Bool)   // "agent finished; 1 file changed"
  func interrupt()
}
protocol FastDecisionProvider {           // Jev
  func decide(_ request: DecisionRequest) async throws -> DecisionResponse   // noul/choice/score
}
protocol CodingAgentProvider {            // Cursor CLI / Cloud / mock
  var executionTarget: AgentExecutionTarget { get }; var isAvailable: Bool { get }
  func start(task: AgentTask, onEvent: @Sendable (AgentEvent) -> Void) async throws -> AgentRunHandle
  func status(runID:) async -> RunningAgentTask?; func cancel(runID:) async throws
}
// diffs come from the checkpoint store (show_agent_diff), not the agent
protocol PerceptionProvider: AnyObject {  // macOS / synthetic
  func start(); func stop(); func snapshot() -> WorldState
  func target(at: Point) -> AttentionTarget?; func capture(rect: Rect) async -> VisualCrop?
}
protocol SourceResolver { func resolve(target:project:) async -> SourceReference? }
protocol CheckpointStore { create/restore/diff/changedFiles }
```

## Schemas

### WorldState (local only)

```
WorldState {
  updatedAt, activeApplication{name,bundleID,pid}, activeWindow{title,bounds,windowID}
  cursorPosition: Point (top-left global)
  hoveredElement: AttentionTarget?      selectedElement: AttentionTarget?
  selectedRegion: Rect?
  recentInteractions: [InteractionEvent{kind: click|drag|keyboard|windowChange|screenChange|hotkeyDown|hotkeyUp, at, position, target?, note}]  // ≤20 s / 60 items
  currentProject: ProjectContext?       currentURL: String?      currentLocalhostPort: Int?
  runningAgents: [RunningAgentTask]     isHotkeyHeld: Bool
}
```

### AttentionTarget

```
AttentionTarget {
  id, role ("AXButton"), label, bounds: Rect, application, applicationBundleID?, window?
  confidence: 0…1
  source: accessibilityHover | explicitClick | explicitRegion | devBridge | recentInteraction | visual | synthetic
  accessibility: { role, subrole, title, descriptionText, value, identifier,
                   domIdentifier, domClassList, ancestorPath[≤6], isEnabled, isFocused }
  visualCrop: { png, bounds, capturedAt }?          // only after capture_target
  sourceReference: { component?, file?, line?, confidence, method }?
  observedAt
}
```

### AgentTask (what Cursor receives)

```
AgentTask {
  id, createdAt, projectName, projectRoot, branch?
  title                 "Make Send Offer button red"
  targetDescription     "button 'Send Offer' in Chrome / localhost:5173"
  target: AttentionTarget?        sourceReference?
  requestedChange       precise imperative, from Grok's proposal or the utterance
  context?              why ("user wants the CTA less dominant")
  constraints[]         "Do not alter other elements", "Preserve design-system conventions", …
  verification[]        "Run the project's lint/type-check if cheap", …
  executionTarget       local | cloud
  proposalID?, resumeSessionID?  (follow-ups resume the same Cursor chat)
}
```
`TaskCompiler.prompt(for:)` renders this as the Project / Target / Source /
Requested change / Context / Constraints / Verification block shown in the
README.

### Permission model

See *Security model*. Encoded in `ToolCatalog.all[*].permission` and
`ExecutionGate.evaluate(level:project:actionKey:isReversal:)`.

## Latency strategy

Measured stages (`LatencyStage`, visible in the debug panel's Latency tab and
in `pair-cli` output): hotkey→listening, voice first packet, target resolution,
context build, jev decision, user transcript, grok first audio, grok tool call,
task compile, checkpoint, agent started, agent first edit, agent finished,
undo, screen capture, request→visible result.

Tactics:
- **Audio bypasses the coordinator queue.** Mic frames go straight to the
  WebSocket; state changes never delay speech.
- **Perception is incremental.** 2 Hz idle / 10 Hz while the hotkey is held;
  the AX element is re-probed only when the pointer moved > 1 pt or the probe is
  stale. App/window/URL are cheap reads.
- **Target resolved twice, cheaply.** Once on hotkey-down (so the outline shows
  immediately) and once on release (pointer may have moved); an explicit click
  short-circuits both.
- **Context is compact JSON**, not screenshots. A `[screen context]` note is
  typically < 600 bytes. Crops only on request.
- **Deterministic before model.** `IntentRouter` handles execution commands,
  undo/redo, ordinals and cancel in microseconds; Jev is consulted only for
  ambiguity and never blocks Grok's response.
- **Persistent Grok session.** One WebSocket for the whole coding session; the
  outbound queue is strictly ordered (append → commit → response.create).
- **Cursor startup is the long pole** (seconds). We start it immediately on
  `execute_change`, stream its events into the orb, and let Grok keep talking.
  Follow-ups pass `--resume <chatId>` so Cursor keeps its own context.
- **Project detection is cached** (20–30 s) and only re-run when the browser
  URL/port or editor window changes.

## Extension points

- New perception source → conform to `PerceptionProvider` or feed
  `WorldState.appendInteraction`.
- New source-mapping strategy → `SourceResolver`, add to the composite chain.
- Another voice or reflex model → `VoiceReasoningProvider` / `FastDecisionProvider`.
- Variants (Milestone 4): `AgentTask` already carries `executionTarget` and
  `proposalID`; `compare_variants` is catalogued; isolating implementations is a
  matter of running two agents on `git worktree`s and switching which one the
  dev server points at.

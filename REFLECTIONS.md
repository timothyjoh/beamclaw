# BeamClaw Phase Reflections

## Phase 3: Phoenix Gateway

### What Worked Well
- **Sequential-then-parallel pattern**: HTTP Engineer scaffolded Phoenix first, then API + LiveView engineers ran in parallel against stubs. No conflicts.
- **Detailed prompts with exact API contracts**: Giving each agent precise Session API signatures meant 3 consumers (RPC Channel, REST, LiveView) all integrated cleanly.
- **Team size of 3 was right**: Focused, well-scoped tasks. No overlap.

### Surprises / Fixes by Lead
1. `Finch.stream/5` vs `stream_while/5` callback return type difference
2. `Plug.Test` deprecation — need `import Plug.Test + import Plug.Conn`
3. Phoenix Router raises `NoRouteError` on 404 (unlike raw Plug)
4. Session test isolation — shared `@test_key` caused `{:error, {:already_started, _}}`

### Improvements for Phase 4+
1. **Mandatory `mix compile` before marking done** — 2 of 3 agents did this; make it a prompt requirement
2. **Each agent writes their own tests** — lead wrote all tests this phase; agents have more context
3. **Shared integration test task** — runs after all agents finish, tests full flow e2e
4. **Session cleanup** — ephemeral sessions in ChatController leak on crash; add monitoring/sweep

### Architecture Updates Needed
- Port 8080 → 4000 (standard Phoenix)
- Cowboy → Bandit
- Supervision tree PubSub position fix
- Add LiveView dashboard to gateway section

---

## Phases 1–4: Full Retrospective (Reflection Agent, 2026-02-14)

This reflection covers all four phases built in a single overnight session (~2.5 hours total) using Claude Code Agent Teams.

### 1. What Each Phase Taught Us About Running Agent Teams

**Phase 1 (Architecture, ~30 min, 3 agents: Researcher + Architect + Devil's Advocate)**
- **Debate-then-synthesize works for design.** Having a Devil's Advocate produce a 700-line critique before synthesis forced the lead to address real concerns (SIGHUP vs SIGTERM, GenServer bottleneck for providers) rather than handwaving.
- **Intermediate artifacts should be disposable.** CRITIQUE.md and DEVILS_ADVOCATE_ANALYSIS.md were deleted after synthesis — the right call. They served their purpose as forcing functions, not deliverables.
- **Model tiering matters.** Sonnet for research teammates, Opus for the lead/synthesizer — good cost/quality tradeoff. Teammates don't need Opus-level reasoning for source reading; the lead needs it for architectural judgment.

**Phase 2 (Core Runtime, ~35 min, 3 agents: Scaffolder + Provider Engineer + Session Engineer)**
- **Clear module boundaries enable true parallelism.** Three agents wrote three independent subsystems (config, provider, session) that composed cleanly. The key was the lead defining exact module APIs before spawning agents.
- **No tests were written.** This was a mistake — Phase 3 had to backfill Session and Store tests. Lesson: every phase prompt must require tests.
- **Context window management is critical.** Phase 1 consumed 89% context, forcing a fresh session for Phase 2. Plan for ~1 fresh session per phase.

**Phase 3 (Gateway, ~40 min, 3 agents)**
- **Sequential-then-parallel is the ideal team pattern.** One agent scaffolds shared infrastructure (Phoenix endpoint, router), then parallel agents build on it. This was the smoothest phase.
- **Lead writing all tests is a bottleneck.** This was called out in the Phase 3 reflection and fixed for Phase 4 — a clear example of the reflection loop working.
- **Integration testing was missing.** No full-flow test (HTTP → Session → Provider mock → response). Added as requirement for Phase 4.

**Phase 4 (Channel/Tools/Cron, ~45 min, agents wrote own tests)**
- **Agents writing their own tests produced 99 new tests** vs. ~29 in Phase 3. Quality and coverage dramatically improved.
- **Phase 4 was the most ambitious scope** — 3 subsystems (channels, tools, cron) with 3,953 lines added. It worked because the architecture.md blueprint was thorough.
- **The Staff Engineer review protocol caught real bugs:** missing `handle_info` clause in Channel.Server, Cron.Store path not being configurable for tests, Exec test cleanup issues. Worth the extra session.
- **Longer phase = longer test suite.** Tests now take 57s due to exec timeout tests. Consider `@tag :slow` for CI optimization.

### 2. Changes Needed to PLAN.md for Phases 5–6

**Phase 5 (Agent Features) — needs scope refinement:**
- **Skill scanner** is well-defined (parse SKILL.md frontmatter) — keep as-is.
- **Tool system** is partially done: `Tool.Exec` and `Tool.WebFetch` already exist from Phase 4. Phase 5 should focus on: `Tool.Browser` (Playwright shim), `Tool.SessionSpawn` (sub-agent), and the tool approval flow (ask modes).
- **Sub-agent spawning** — architecture.md defines the pattern but the Session GenServer doesn't have `parent_session` or `sub_agents` fields yet. This is a real gap.
- **Heartbeat runner** — simple, but not defined in architecture.md beyond a one-liner. Needs a brief spec (what does it check? what does it broadcast?).
- **Recommended team split:** Skill Engineer, Tool Engineer (browser + session_spawn), Cron/Heartbeat Engineer. Three agents, well-scoped.

**Phase 6 (Distribution) — needs prerequisites:**
- **Telemetry should be Phase 5, not Phase 6.** `:telemetry` + LiveDashboard is a standalone concern, easy to add, and immediately useful for debugging Phases 5+ in dev. Don't bundle it with the hard distribution work.
- **Distribution scope is enormous.** libcluster + :pg + Horde + agent migration is 3 phases of work, not 1. Consider splitting: Phase 6a (telemetry + LiveDashboard), Phase 6b (clustering + distributed registry), Phase 6c (agent migration + hot code reload).

### 3. Prompting Improvements for the Next Team

**Mandatory in every agent prompt:**
1. `Run mix compile --warnings-as-errors before marking your task done.`
2. `Write unit tests for every public function in the modules you create.`
3. `Do NOT modify files assigned to other agents. If you need an API from another module, define the expected interface in your code and document the dependency.`

**Structural improvements:**
- **Give agents the exact file paths they should create.** Phase 4 went smoothly because agents knew `lib/beamclaw/tool/exec.ex`, `lib/beamclaw/cron/worker.ex`, etc. up front. Ambiguity about where code lives causes merge conflicts.
- **Include a "done criteria" checklist** in each agent's prompt: compiles, tests pass, no warnings, module registered in application.ex if needed.
- **For the lead prompt:** Include "After all agents finish, run `mix test` across the full project. Fix any cross-module integration issues before committing."

**Anti-patterns to call out explicitly:**
- "Do NOT wrap provider calls in additional Tasks — the provider already spawns an async Task." (This bit Phase 2.)
- "Use `Finch.stream/5` (NOT `stream_while/5`). The callback returns a plain accumulator, NOT `{:cont, acc}`." (This bit Phases 2 and 3.)
- "Test isolation: always use unique keys per test. Never share module attributes like `@test_key` across tests." (This bit Phase 3.)

### 4. Architecture.md Updates Needed Based on What Was Actually Built

**Section 3 (Supervision Tree) — needs update:**
- Missing: `BeamClaw.BackgroundProcessRegistry` (added in Phase 4, should be in the tree)
- Port listed as 8080, should be 4000 (Bandit, not Cowboy)
- `ProviderStats`, `NodeRegistry`, and `HeartbeatRunner` are in the diagram but **not yet implemented**. Mark them as "Phase 5/6" to avoid confusion.
- Actual startup order: Registry → Finch → PubSub → Config → BackgroundProcessRegistry → ToolSupervisor → SessionSupervisor → ChannelSupervisor → CronSupervisor → Endpoint

**Section 4.2 (Sessions) — diverges from implementation:**
- Architecture says "sessions are lightweight metadata holders, not message stores." But the actual Session GenServer holds `messages: []` (full history) in state. This is the right call for Phase 2–5 (simple, works), but architecture.md should acknowledge the divergence and note that message history offloading is a Phase 6 concern.
- `State` struct in code is simpler than architecture.md's spec: no `sub_agents`, `monitors`, `parent_session` fields yet. These should be added in Phase 5.

**Section 4.4 (Tools) — partially implemented:**
- `Tool.Exec` and `Tool.WebFetch` exist. `Tool.Browser` and `Tool.SessionSpawn` do not.
- Tool approval flow (ask modes) is not implemented. Mark as Phase 5.
- Background process registry matches the spec well.

**Section 4.5 (Channels) — matches well:**
- Channel behaviour matches architecture.md closely. Discord adapter uses Nostrum as planned.
- `gateway_methods/0` optional callback is in the spec but not in the implementation — minor gap.

**Section 4.6 (Cron) — matches well:**
- Cron.Worker, Cron.Store, Cron.Schedule all implemented. Stuck detection, auto-disable, atomic JSONL writes all present.
- Schedule parsing supports at/every/cron as specified.

**New section needed: Gateway (Section 4.1 update)**
- LiveView dashboard exists but isn't mentioned in architecture.md
- `/health` endpoint exists but isn't in the architecture
- The actual Router pipeline structure (`:browser` + `:api`) should be documented

### 5. Meta-Observations About This Overnight Autonomous Build

**What worked exceptionally well:**
- **Architecture-first paid off enormously.** Phase 1's 656-line blueprint meant Phases 2–4 rarely had to make design decisions — they just implemented the spec. The upfront 30-minute investment saved hours of rework.
- **The reflection loop is real.** Phase 3 reflection said "agents should write their own tests." Phase 4 agents wrote 99 tests. Phase 3 said "add integration tests." Phase 4 included `integration_test.exs`. The protocol works.
- **Pace was remarkable:** 4 phases, 28 source files, 17 test files, 128 passing tests, ~7,600 lines of code — in ~2.5 hours. That's a production-quality Elixir project from zero.
- **Staff Engineer review as a separate session** catches issues that the building team is blind to (context fatigue). Worth the cost of an extra Opus session per phase.

**What could be better:**
- **No manual QA happened.** All validation was automated (`mix test`, `mix compile`). Nobody actually ran `iex -S mix` and chatted with the bot end-to-end during the build. The LiveView dashboard was never visually tested. Phase 5 should include a manual smoke test step.
- **Test execution time is already 57s** and will grow. Need `mix test --exclude slow` for fast feedback loops, `mix test` for CI.
- **Phase scope creep risk.** Phase 4 was labeled "Channel System" in PLAN.md but actually built channels + tools + cron (3 subsystems). This worked because they were independent, but it stretches the "one concern per phase" principle. For Phase 5, keep it tight.
- **No error recovery testing.** Tests verify happy paths and some edge cases, but there's no chaos testing (what happens when Anthropic returns 500? When a session crashes mid-stream? When Nostrum disconnects?). Phase 5 should add fault injection tests.
- **Documentation drift.** architecture.md is already behind the implementation after just 4 phases. Consider generating a "living architecture" doc from the supervision tree and module docs, or update architecture.md as part of each phase's commit.

**The overnight autonomous pattern:**
- Total human intervention: ~5 touches (phase launches + Discord check-ins). Claude Code Agent Teams handled everything else autonomously.
- The key enabler was `PHASE_PROTOCOL.md` — a repeatable checklist that turns phase completion from ad-hoc into a process. This is worth reusing for any multi-phase project.
- Context window is the real constraint, not capability. Each phase needs a fresh session. Plan accordingly: keep team prompts self-contained with all necessary context (don't assume carryover).
- **Cost was low:** ~5% of Claude Max weekly limit for 4 phases. This scales to much larger projects.

---

## Phase 5: Agent Features (Reflection Agent, 2026-02-14)

### 1. What Phase 5 Taught Us

**Phase 5 (Agent Features, ~30 min, 5 modules: Skill + Agent + SubAgent + Approval + Registry)**

Phase 5 was the "intelligence layer" — the modules that make BeamClaw an agent platform rather than just a chat proxy. Key learnings:

- **ETS for cross-process coordination works well.** Both `Tool.Approval` and `Tool.Registry` use ETS tables initialized in `application.ex` (owned by the application master, so they outlive any individual GenServer). This is the right pattern for shared mutable state that multiple sessions need to read/write concurrently without a GenServer bottleneck. The Staff Engineer review caught that `Tool.Registry` needed concurrent read access tests — good validation of the review protocol.

- **Sub-agent depth enforcement is simple but critical.** `Session.SubAgent` enforces the 1-level-deep rule from OpenClaw. The implementation is clean: check `parent_session != nil` before allowing spawn. Process monitoring via `Process.monitor/1` handles cleanup when sub-agents crash. This is a textbook "let it crash" pattern — no defensive error handling needed because the supervisor and monitors handle everything.

- **Skill loading is filesystem-based and stateless — correct tradeoff.** `BeamClaw.Skill` parses YAML frontmatter from SKILL.md files on demand, no caching GenServer needed. Skills are read infrequently (agent init) and the filesystem is the source of truth. Adding a watcher for hot-reload later is trivial because there's no cache to invalidate.

- **Tool.Approval using PubSub for request/response is elegant.** The approval flow broadcasts `{:approval_request, ...}` via PubSub and waits for `{:approval_response, ...}` with a 120s timeout. Any connected client (LiveView, WebSocket, CLI) can respond. This decouples the approval UI from the tool execution path — a clear BEAM advantage over OpenClaw's callback-based approach.

- **The Agent module is thin by design.** `BeamClaw.Agent` is essentially a configuration resolver: given an agent ID, it loads config, resolves skills, and returns a struct. It does NOT own a process — sessions are the unit of execution. This avoids the "god object" anti-pattern that plagues agent frameworks.

- **Lead extended-thinking stalls are a real problem.** The lead agent got stuck in 10-12 minute thinking loops twice during Phase 5 (noted in DECISIONS.md). This wastes time and context window. Future prompts should include: "Do not think for more than 2 minutes on any single decision. If stuck, make a pragmatic choice and document the tradeoff."

### 2. Changes Needed to PLAN.md for Phase 6

**Phase 6 scope is still too large.** The current plan lists clustering, agent migration, and hot code reload as one phase. The Phase 1-4 reflection already recommended splitting this. With Phase 5 complete, here's the refined breakdown:

**Phase 6a: Telemetry & Observability**
- `:telemetry` events on provider calls, tool execution, session lifecycle
- LiveDashboard integration (already have Phoenix — just add the dependency)
- ProviderStats GenServer (ETS-backed usage tracking — designed in architecture.md but not built)
- HeartbeatRunner (periodic health check, presence broadcasting)
- This is low-risk, high-value, and should take ~20 min with a 2-agent team

**Phase 6b: Clustering & Distribution**
- `libcluster` for node discovery (Gossip strategy for dev, Kubernetes for prod)
- `:pg` (process groups) for distributed session/channel discovery
- Replace `Registry` lookups with `:pg` for cross-node resolution
- PubSub already distributed via Phoenix.PubSub — just needs node connections
- This is medium-risk; the main challenge is testing multi-node in CI

**Phase 6c: Agent Migration & Hot Reload**
- Horde for distributed DynamicSupervisor (session handoff between nodes)
- Session state serialization/deserialization for migration
- Connection draining (graceful node shutdown)
- Hot code reload for skills/config without process restart (partially done — Config already watches filesystem)
- This is high-risk and may need to be deferred to Phase 7

**Phase 5 items NOT completed (defer or drop):**
- `Tool.Browser` (Playwright shim) — intentionally deferred. Requires Node.js dependency and Erlang Port management. Not needed for core agent functionality. Recommend Phase 7 or community contribution.
- `HeartbeatRunner` — designed in architecture.md, not implemented. Move to Phase 6a.
- `ProviderStats` — designed, not implemented. Move to Phase 6a.
- `NodeRegistry` (device pairing/auth) — designed, not implemented. Move to Phase 6b.
- Fault injection tests — recommended in Phase 1-4 reflection, not done. Add to Phase 6a alongside telemetry.

### 3. Prompting Improvements

**New anti-patterns discovered in Phase 5:**

1. **"Do NOT initialize ETS tables inside GenServer.init/1 if the table needs to outlive the GenServer."** Phase 5 correctly placed `Tool.Approval.init()` and `Tool.Registry.init()` in `application.ex`, but this pattern should be called out explicitly in prompts — it's a common Elixir mistake.

2. **"Include max thinking time in lead prompts."** The lead agent's extended thinking stalls (10-12 min) are pure waste. Add: "If you are thinking for more than 2 minutes, stop thinking and make a decision. Document tradeoffs in DECISIONS.md."

3. **"Specify test count expectations."** Phase 5 produced 79 new tests (207 total). Phase 4 produced 99 new tests. Setting a floor ("each module should have at least 10 tests covering happy path, error cases, and edge cases") prevents undertesting.

**Prompts that worked well (keep):**
- "Run `mix compile --warnings-as-errors` before marking done" — caught real issues
- "Write unit tests for every public function" — enforced by agents consistently since Phase 4
- Exact file paths in prompts — zero merge conflicts across all 5 phases
- "Done criteria" checklist — every agent knew when they were actually done

**Structural prompt improvement:**
- **Add a "do NOT implement" list.** Phase 5 could have scope-crept into HeartbeatRunner, ProviderStats, or Tool.Browser. Explicitly listing what's out of scope prevents agents from gold-plating.

### 4. Architecture.md Updates Needed

**Section 3 (Supervision Tree):**
- `ProviderStats`, `NodeRegistry`, `HeartbeatRunner` are still marked ⏳ Phase 5 — update to ⏳ Phase 6a/6b
- Add note: ETS tables for `Tool.Approval` and `Tool.Registry` are initialized in `application.ex`, not in the supervision tree
- Application startup now includes `BeamClaw.Tool.Approval.init()` and `BeamClaw.Tool.Registry.init()` before supervisor starts

**Section 4.2 (Sessions) — update for sub-agents:**
- Session GenServer now has `sub_agents`, `monitors`, and `parent_session` fields (added in Phase 5)
- `BeamClaw.Session.SubAgent` module handles spawning, monitoring, and depth enforcement
- Sub-agent cleanup happens via `Process.monitor/1` + `handle_info({:DOWN, ...})`

**New Section: 4.7 Agent Intelligence Layer (Phase 5)**
- `BeamClaw.Skill` — filesystem-based skill loading, YAML frontmatter parsing
- `BeamClaw.Agent` — agent configuration resolver (not a process)
- `BeamClaw.Tool.Approval` — ETS-backed approval flow with PubSub coordination
- `BeamClaw.Tool.Registry` — per-session ETS tool registration with scoping

**Section 13 (Implementation Roadmap):**
- Phase 5 description should reflect what was actually built vs. what was deferred
- Phase 6 should be split into 6a/6b/6c as described above

### 5. Meta-Observations: The Full 5-Phase Overnight Build

**By the numbers:**
- 5 phases, ~3 hours total wall time
- 42 source files (`.ex`), 23 test files
- 210 tests, 0 failures
- ~10,500 lines of Elixir (source + tests)
- 10 git commits (5 phase commits + 3 staff reviews + 1 reflection + 1 initial)
- Cost: estimated ~8-10% of Claude Max weekly limit

**The architecture-first approach was the single most important decision.**
Phase 1's 656-line architecture.md eliminated almost all design decisions from Phases 2-5. Agents didn't debate "should we use GenServer or Agent?" — the blueprint said GenServer, so they implemented GenServer. This is the #1 recommendation for any multi-phase autonomous build: spend 20% of your time on architecture, and the remaining 80% is mostly mechanical.

**The reflection loop compound-improved quality across phases.**
- Phase 3 reflection: "agents should write their own tests" → Phase 4: 99 tests (3x improvement)
- Phase 3 reflection: "add integration tests" → Phase 4: `integration_test.exs` with full flow coverage
- Phase 1-4 reflection: "add Staff Engineer review" → Phase 5: Staff review caught `Tool.Registry` concurrency gap
- Each phase was measurably better than the last. This is the key argument for explicit reflection steps between phases.

**The BEAM choice validated itself progressively:**
- Phase 2: Process mailbox as message queue (no external dependency)
- Phase 3: Phoenix PubSub for event broadcasting (trivial)
- Phase 4: DynamicSupervisor for channels/cron (automatic restart on crash)
- Phase 5: ETS for shared state, Process.monitor for sub-agent lifecycle
- Each phase leveraged a different BEAM primitive naturally. The platform fit is real, not theoretical.

**What the full build revealed about agent team scaling:**
- **3 agents per phase is the sweet spot.** Enough parallelism to matter, few enough to avoid coordination overhead.
- **The lead agent is the bottleneck.** Lead runs integration tests, fixes cross-module issues, writes the commit. This serialized work is ~30% of each phase's time. Consider a "test runner" agent that works in parallel with the lead on integration.
- **Context window management is the hardest constraint.** Each phase needs a fresh session. The lead must include all necessary context in prompts — no assuming carryover. This makes prompt quality critically important.
- **Staff Engineer review as a separate session is worth the cost.** Fresh eyes catch what fatigued eyes miss. The 5-10 minute investment per phase prevented bugs from compounding across phases.

**What's left for Phase 6+ and beyond:**
BeamClaw is now a complete single-node agent orchestration platform: config loading, multi-provider LLM integration, session management, channel adapters, tool execution, cron scheduling, skill loading, sub-agent spawning, and tool approval. The "why BEAM" story is proven for single-node. Phase 6 is where BEAM's distribution story turns from theoretical advantage to practical differentiator — clustering, agent migration, and hot code reload are things that simply cannot be done in Node.js without fundamental re-architecture. See `docs/VISION.md` for the full scaling vision.

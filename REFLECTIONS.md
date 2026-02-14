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

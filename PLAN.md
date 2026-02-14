# BeamClaw — BEAM/Elixir Implementation of OpenClaw

## Vision
A production-quality reimplementation of OpenClaw on BEAM/OTP, leveraging Erlang's structural advantages for AI agent orchestration: fault tolerance, millions of lightweight processes, supervision trees, hot code reloading, and built-in distribution.

## Source Reference
- OpenClaw source: `~/wrk/opc/openclaw/` (~311K lines TypeScript, ~1700 files)
- Key directories: `src/gateway/`, `src/agents/`, `src/sessions/`, `src/channels/`, `src/cron/`, `src/infra/`

## Architecture Mapping (Node.js → BEAM)

| OpenClaw (Node.js) | BeamClaw (Elixir) |
|---|---|
| Gateway daemon (single process) | Application supervision tree |
| Sessions (in-memory + JSONL) | GenServer per session under DynamicSupervisor |
| Channels (Discord, Telegram, etc.) | GenServer per channel with behaviour |
| Cron scheduler | `:timer` / custom GenServer scheduler |
| WebSocket connections | Cowboy/Phoenix WebSocket handlers |
| Config (YAML/JSON) | Application config + runtime config |
| Skills (markdown + scripts) | Same (filesystem-based, no change needed) |
| Tools (exec, browser, etc.) | GenServer per tool with timeout/kill support |
| Heartbeat runner | Periodic GenServer with `:timer.send_interval` |
| Provider routing (Anthropic, OpenAI) | Behaviour + adapter pattern |
| Sub-agents / sessions_spawn | `Task.Supervisor.async_nolink` or DynamicSupervisor |
| Message queuing | Process mailbox (native!) |
| File locks | `:global` or `:pg` for distributed locks |

## Phases

### Phase 1: Architecture & Foundation
**Goal:** Deep-dive into OpenClaw's architecture, map every subsystem to BEAM patterns, produce a detailed technical spec.
- Analyze OpenClaw source: gateway, agents, sessions, channels, providers, tools
- Map each subsystem to Elixir/OTP patterns
- Design supervision tree hierarchy
- Define module boundaries and behaviours
- Output: `docs/architecture.md` — the blueprint

### Phase 2: Core Runtime
**Goal:** Boot a BEAM application that can load config, manage sessions, and route messages.
- Mix project scaffolding
- Application supervisor + config loading
- Session GenServer (create, send message, get history)
- JSONL persistence (like OpenClaw's approach)
- Basic provider adapter (Anthropic HTTP client)
- Output: A running `iex -S mix` that can create a session and get an AI response

### Phase 3: Gateway & API
**Goal:** HTTP/WebSocket gateway that speaks OpenClaw's protocol.
- Phoenix or Plug-based HTTP server
- Chat completions endpoint (OpenAI-compatible)
- WebSocket connection for real-time sessions
- Gateway RPC (restart, config, status)
- Authentication (API keys, device auth)
- Output: `curl` can hit the API and get responses

### Phase 4: Channel System
**Goal:** Connect to messaging platforms (Discord first, then others).
- Channel behaviour definition
- Discord channel (using Nostrum or raw WebSocket)
- Message normalization (platform → internal → platform)
- Inbound message routing → session → response → outbound
- Output: Bot responds on Discord

### Phase 5: Agent Features
**Goal:** Skills, tools, cron, heartbeats — the agent intelligence layer.
- Skill scanner (parse SKILL.md frontmatter, same as OpenClaw)
- Tool system (exec, browser, web_fetch, etc.)
- Cron scheduler (at/every/cron expressions)
- Heartbeat runner
- Sub-agent spawning (extracting into that BEAM sweet spot)
- Output: A fully functional agent that can run skills and tools

### Phase 6: Distribution & Advanced
**Goal:** The things only BEAM can do natively.
- Multi-node clustering (`libcluster`)
- Agent migration between nodes
- Hot code reloading for skills/config
- Telemetry & observability (`:telemetry` + LiveDashboard)
- Output: Agents running across multiple machines with zero downtime updates

## Development Method
Each phase is tackled by a Claude Code Agent Team:
- **Architect** — designs the BEAM patterns
- **Researcher** — reads OpenClaw source, extracts behavior
- **Devil's Advocate** — challenges assumptions, finds holes
- Lead synthesizes findings into actionable specs

Rita (meta-orchestrator) monitors progress, captures learnings, and spawns new teams per phase.

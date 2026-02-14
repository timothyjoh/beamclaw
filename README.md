# BeamClaw

A BEAM/Elixir reimplementation of [OpenClaw](https://github.com/anthropics/openclaw) — AI agent orchestration built on OTP primitives.

BeamClaw replaces a ~311K-line TypeScript codebase with ~5,000 lines of Elixir, leveraging the BEAM's structural advantages: supervision trees for fault tolerance, lightweight processes for per-session concurrency, ETS for lock-free shared state, and native distribution for multi-node clustering.

## Status

**Phases 1-6a complete.** Single-node agent platform with multi-tenant foundation, telemetry, and clustering primitives. Built in ~3 hours using Claude Code Agent Teams.

| Metric | Value |
|--------|-------|
| Source files | 38 `.ex` modules |
| Test files | 27 `.exs` files |
| Tests | 274 passing, 0 failures |
| Total Elixir | ~12,500 lines (source + tests) |
| Git commits | 12 |
| Dependencies | 16 (Phoenix, Finch, Nostrum, libcluster, etc.) |

## Architecture

```
BeamClaw.Application (Supervisor)
├── Registry          — process lookup ({:session, key}, {:channel, id}, {:cron, agent_id})
├── Finch             — HTTP/2 connection pools for LLM APIs
├── PubSub            — event broadcasting (Phoenix.PubSub)
├── Config            — YAML config + FileSystem watcher for hot-reload
├── Tenant.Manager    — multi-tenant supervision trees
├── Telemetry         — :telemetry events + LiveDashboard metrics
├── Cluster           — libcluster + :pg process groups
├── ToolSupervisor    — ephemeral tool execution (Task.Supervisor)
├── SessionSupervisor — GenServer-per-session (DynamicSupervisor)
├── ChannelSupervisor — platform adapters (DynamicSupervisor)
├── CronSupervisor    — per-agent scheduled jobs (DynamicSupervisor)
└── Gateway.Endpoint  — Phoenix (Bandit on port 4000)
    ├── /                        LiveView dashboard
    ├── /dashboard               LiveDashboard (telemetry)
    ├── /v1/chat/completions     OpenAI-compatible REST (streaming SSE)
    ├── /health                  Health check
    └── /ws                      WebSocket RPC channel
```

## Features

- **Session Management** — GenServer-per-session with JSONL persistence, message history, streaming responses
- **LLM Providers** — Anthropic adapter with SSE streaming via Finch HTTP/2; provider behaviour for adding others
- **Channel System** — Behaviour-based platform adapters (Discord via Nostrum included)
- **Tool Execution** — `Tool.Exec` (sandboxed shell with env blocklist, background process registry, SIGTERM/SIGKILL escalation), `Tool.WebFetch` (HTTP fetching)
- **Cron Scheduling** — Per-agent workers with `at`/`every`/`cron` schedules, stuck detection, auto-disable after 3 consecutive errors
- **Skill Loading** — Filesystem-based SKILL.md parsing (YAML frontmatter)
- **Agent Configuration** — Stateless resolver for model, provider, skills, tool allowlist
- **Sub-Agent Spawning** — 1-level-deep enforcement, Process.monitor cleanup
- **Tool Approval** — Ask modes (off/on_miss/always), PubSub-coordinated approval flow with 120s timeout
- **Tool Registry** — Per-session ETS-backed tool registration and scoping
- **Multi-Tenancy** — Per-tenant supervision subtrees with resource isolation
- **Telemetry** — 20 instrumented metrics across provider, session, tool, and cron paths; LiveDashboard integration
- **Clustering** — libcluster (Gossip/K8s DNS), `:pg` process groups for distributed discovery

## Quick Start

```bash
# Prerequisites: Elixir 1.16+, Erlang/OTP 26+
git clone <repo-url> beamclaw && cd beamclaw

# Install dependencies
mix deps.get

# Configure (optional — works without config for basic usage)
mkdir -p ~/.config/beamclaw
cp config/config.exs.example ~/.config/beamclaw/config.yaml  # if available

# Set your API key
export ANTHROPIC_API_KEY=sk-ant-...

# Start interactive session
iex -S mix

# Or run tests
mix test
```

### Usage from IEx

```elixir
# Create a session and send a message
{:ok, pid} = BeamClaw.Session.start_link(session_key: "agent:default:main")
BeamClaw.Session.send_message(pid, "Hello, what can you do?", reply_to: self())

# Receive streaming response
flush()
```

### HTTP API

```bash
# Health check
curl http://localhost:4000/health

# Chat completion (OpenAI-compatible, streaming)
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet-4-20250514", "messages": [{"role": "user", "content": "Hello"}], "stream": true}'
```

### LiveView Dashboard

Visit `http://localhost:4000` for the session management and chat dashboard.
Visit `http://localhost:4000/dashboard` for LiveDashboard (telemetry metrics).

## Project Structure

```
lib/beamclaw/
├── application.ex              # OTP application + supervision tree
├── config.ex                   # YAML config loading + FileSystem watcher
├── cluster.ex                  # libcluster + :pg integration
├── telemetry.ex                # :telemetry event definitions + metrics
├── tenant.ex                   # Tenant struct
├── tenant/
│   ├── manager.ex              # Multi-tenant lifecycle management
│   └── supervisor.ex           # Per-tenant supervision subtree
├── provider.ex                 # Provider behaviour
├── provider/
│   ├── anthropic.ex            # Anthropic API client (Finch + SSE)
│   └── sse.ex                  # Server-Sent Events parser
├── session.ex                  # Session GenServer
├── session/
│   ├── store.ex                # JSONL persistence (atomic writes)
│   └── sub_agent.ex            # Sub-agent spawning + depth enforcement
├── agent.ex                    # Agent configuration resolver
├── skill.ex                    # SKILL.md loader (YAML frontmatter)
├── channel.ex                  # Channel behaviour
├── channel/
│   ├── server.ex               # Channel GenServer
│   ├── discord.ex              # Discord adapter (Nostrum)
│   └── mock_adapter.ex         # Test adapter
├── cron/
│   ├── worker.ex               # Per-agent cron GenServer
│   ├── store.ex                # JSONL job persistence
│   └── schedule.ex             # at/every/cron schedule parsing
├── tool/
│   ├── exec.ex                 # Shell execution (sandboxed)
│   ├── web_fetch.ex            # HTTP fetching
│   ├── approval.ex             # Tool approval flow (ETS + PubSub)
│   └── registry.ex             # Per-session tool registry (ETS)
├── background_process_registry.ex  # Long-running process tracking
└── gateway/
    ├── endpoint.ex             # Phoenix.Endpoint (Bandit)
    ├── router.ex               # Routes (browser + API pipelines)
    ├── chat_controller.ex      # /v1/chat/completions
    ├── health_controller.ex    # /health
    ├── rpc_channel.ex          # WebSocket JSON-RPC
    ├── user_socket.ex          # Phoenix.Socket
    ├── dashboard_live.ex       # LiveView dashboard
    └── layouts/                # HTML templates
```

## Why BEAM?

Every other agent framework solves distribution, fault tolerance, and multi-tenancy by bolting on Kubernetes, Redis, RabbitMQ, and service meshes. BeamClaw starts with a runtime where these properties are built in:

- **Fault tolerance** — Supervision trees replace defensive try/catch. A crashed session restarts automatically.
- **Concurrency** — One process per session, per channel, per cron job. No thread pools, no callback hell.
- **Message queuing** — Process mailboxes are native queues. No external dependencies.
- **Live introspection** — `:observer.start()`, `:sys.get_state(pid)`, tracing in production.
- **Distribution** — Multi-node clustering via `Node.connect/1`. No message broker needed.
- **Hot code reload** — Deploy new agent code without dropping connections.

See [docs/VISION.md](docs/VISION.md) for the full scaling story.

## Development

```bash
mix test                              # Run full test suite (~57s)
mix test --exclude slow               # Fast feedback loop
mix compile --warnings-as-errors      # Strict compilation
iex -S mix                            # Interactive development
```

## Roadmap

- [x] Phase 1: Architecture blueprint (docs/architecture.md)
- [x] Phase 2: Core Runtime (Config, Session, Provider, JSONL)
- [x] Phase 3: Gateway (Phoenix, REST, WebSocket, LiveView)
- [x] Phase 4: Channels, Tools, Cron
- [x] Phase 5: Skills, Agents, Sub-Agents, Tool Approval/Registry
- [x] Phase 6a: Telemetry, Multi-Tenancy, Clustering primitives
- [ ] Phase 6b: Distributed registry (`:pg` replacing `Registry` for cross-node)
- [ ] Phase 6c: Agent migration, hot reload, connection draining
- [ ] Phase 7+: Agent marketplace, federation (see VISION.md)

## How It Was Built

BeamClaw was built from zero in ~3 hours using Claude Code Agent Teams — an autonomous multi-agent workflow where:
- A **Phase 1 team** (Researcher + Architect + Devil's Advocate) produced the 656-line architecture blueprint
- **Phases 2-6a teams** (3 agents each) implemented subsystems in parallel against the blueprint
- A **Staff Engineer review** agent ran after each phase to catch bugs
- A **Reflection Agent** captured learnings between phases, driving measurable quality improvements

See [REFLECTIONS.md](REFLECTIONS.md) for the full retrospective.

## License

MIT

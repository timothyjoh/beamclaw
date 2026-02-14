# BeamClaw Architecture — BEAM/OTP Technical Blueprint

**Status:** LIVING DOCUMENT — Phase 1 origin, updated through Phase 5
**Date:** 2026-02-14
**Authors:** Phase 1 Agent Team (Researcher, Architect, Devil's Advocate, Team Lead)

---

## 1. Executive Summary

BeamClaw is a BEAM/Elixir reimplementation of OpenClaw, a ~311K-line TypeScript AI agent orchestration platform. This document is the comprehensive technical blueprint produced by Phase 1 — a deep analysis of OpenClaw's architecture mapped to idiomatic BEAM/OTP patterns.

**Key architectural decisions:**

- **Phoenix-based Gateway** with custom RPC channel implementing OpenClaw's WebSocket protocol
- **GenServer-per-session** under DynamicSupervisor — sessions are lightweight metadata holders, not message stores
- **Stateless provider modules** with Finch HTTP/2 connection pools — eliminates the single-GenServer bottleneck
- **Per-agent cron workers** under DynamicSupervisor — matches OpenClaw's per-agent isolation
- **Background process registry** for long-running exec commands that yield after 10s
- **Async message flow** — sessions never block callers; streaming via process message passing

**Where BEAM wins over Node.js for this domain:**
- Fault tolerance via supervision trees (no defensive try/catch everywhere)
- Process-per-session concurrency (no callback hell, no promise pools)
- Native message queuing (no external queue like Bull/BeeQueue)
- Live introspection in production (Observer, `:sys.get_state/1`, tracing)
- Distribution-ready architecture (multi-node clustering in Phase 6)

**Critical risks identified:**
- No official Elixir SDKs from Anthropic or OpenAI (community libs only)
- No mature native browser automation (must shell out to Node.js Playwright)
- Erlang ports send SIGHUP on close, not SIGTERM — need MuonTrap or manual signal handling
- JSONL persistence is simple but won't scale to analytics or multi-node

---

## 2. OpenClaw Architecture Overview

*Source: ~/wrk/opc/openclaw/ (~311K lines TypeScript, ~1700 files)*

### 2.1 Subsystem Map

| Subsystem | Key Files | Role |
|-----------|-----------|------|
| **Gateway** | `server.impl.ts`, `server-ws-runtime.ts`, `protocol/` | Single-process WS RPC server, HTTP endpoints, lifecycle |
| **Sessions** | `gateway/session-utils.ts`, `config/sessions.ts` | JSONL metadata store, session key routing (`agent:ID:SESSION`) |
| **Agents** | `commands/agent.ts`, `agents/cli-runner.ts` | Agent initialization, skill loading, model/provider resolution |
| **Channels** | `channels/plugins/`, `discord/`, `telegram/`, `slack/` | Platform adapters with ChannelPlugin interface |
| **Providers** | `providers/`, `agents/model-fallback.ts` | LLM API clients, streaming SSE, fallback chains |
| **Tools** | `agents/bash-tools.exec-runtime.ts`, `agents/tools/` | Exec (with security model), browser, web_fetch, session_spawn |
| **Cron** | `cron/service/jobs.ts`, `cron/service/timer.ts` | Per-agent job scheduling (at/every/cron), JSONL persistence |

### 2.2 Critical Patterns Discovered

**Gateway Protocol:** Custom WebSocket JSON-RPC — `hello` handshake with protocol version, typed request/response/event frames, broadcast to all connected clients.

**Session Persistence:** JSONL stores **session metadata only** (display name, channel, thinking level, model override) — NOT individual messages. Entire store written atomically via temp file + rename. Message history lives in the agent runtime (in-memory).

**Session Key Routing:** Format `agent:AGENT_ID:SESSION_ID` (e.g., `agent:ops:main`). Case-insensitive, with legacy key cleanup.

**Sub-Agent Spawning:** Hard-capped at **1 level deep**. Sub-agents cannot spawn sub-agents — explicitly blocked in code. Parent controls allowlist.

**Tool Execution Security:** Three modes — sandbox (Docker), gateway (host with env restrictions), node (remote). Dangerous env vars blocked: `LD_PRELOAD`, `NODE_OPTIONS`, `PATH`, etc. Background processes yield after 10s with a process registry for tail/kill. SIGTERM → SIGKILL escalation.

**Tool Approval Flow:** Tools support ask modes (off/on-miss/always) with 120s approval timeout.

**Cron Per-Agent Isolation:** Each agent has its own cron store (`cron/{agentId}.cron.jsonl`). Job types: main (runs in main session) vs isolated (spawns ephemeral session, cleaned up after 24h). Stuck run detection at 2h, auto-disable after 3 consecutive errors.

**Streaming:** Event-driven callbacks — `onAssistantUpdate`, `onToolCall`, `onToolResult`, `onUsageUpdate`. Non-blocking. Delta buffers accumulate in state.

---

## 3. Supervision Tree

```
BeamClaw.Application (Supervisor, strategy: :one_for_one)
│
├── BeamClaw.Registry (Registry, keys: :unique)
│   Process lookup: {:session, id}, {:channel, id}, {:cron, agent_id}
│
├── Finch (BeamClaw.Finch)
│   HTTP/2 connection pools for LLM provider APIs
│
├── Phoenix.PubSub (BeamClaw.PubSub)
│   Event broadcasting: "events:global", "session:{id}", "agent:{id}"
│
├── BeamClaw.Config (GenServer)
│   ├── Loads/validates YAML config at startup
│   └── FileSystem watcher (linked) for hot-reload
│       Hot-reloadable: timeouts, feature flags, cron, channel settings
│       Requires restart: API keys, provider URLs, bind mode, TLS
│
├── BeamClaw.BackgroundProcessRegistry (GenServer)                    ✅ Phase 4
│   Tracks long-running exec processes (yield after 10s, tail output, kill)
│
├── BeamClaw.ToolSupervisor (Task.Supervisor)
│   Short-lived tool execution tasks (:temporary — never restart)
│
├── BeamClaw.SessionSupervisor (DynamicSupervisor)
│   Session GenServers (:transient — restart on abnormal exit)
│
├── BeamClaw.ChannelSupervisor (DynamicSupervisor)                   ✅ Phase 4
│   Channel GenServers (:transient — restart on crash for reconnection)
│
├── BeamClaw.CronSupervisor (DynamicSupervisor)                      ✅ Phase 4
│   Per-agent Cron.Worker GenServers (:transient)
│
├── BeamClaw.ProviderStats (GenServer)                                ⏳ Phase 6a
│   ETS table owner for usage tracking (requests, tokens, cost per provider/day)
│
├── BeamClaw.NodeRegistry (GenServer)                                 ⏳ Phase 6b
│   Device pairing, authentication, presence tracking
│
├── BeamClaw.HeartbeatRunner (GenServer)                              ⏳ Phase 6a
│   Periodic health checks, presence broadcasting
│
└── BeamClaw.Gateway.Endpoint (Phoenix.Endpoint)                     ✅ Phase 3
    ├── Bandit HTTP server (port 4000)
    │   ├── /v1/chat/completions (OpenAI-compatible REST, streaming SSE)
    │   ├── /health
    │   └── / (LiveView dashboard — session management + chat)
    └── WebSocket at /ws
        └── BeamClaw.Gateway.RPCChannel (Phoenix.Channel)
            Custom JSON-RPC protocol: hello → request/response → events
```

> **Implementation note (Phase 5):** The actual startup order in `application.ex` is:
> `Tool.Approval.init()` + `Tool.Registry.init()` (ETS tables) →
> Registry → Finch → PubSub → Config → BackgroundProcessRegistry → ToolSupervisor →
> SessionSupervisor → ChannelSupervisor → CronSupervisor → Endpoint.
> ETS tables for Tool.Approval and Tool.Registry are initialized before the supervisor
> starts so they outlive any individual GenServer. Items marked ⏳ are designed but not yet implemented.

**Shutdown ordering** (reverse startup): Gateway → Heartbeat → Cron → Channels → Sessions → Tools → BackgroundProcessRegistry → NodeRegistry → Config → Finch → PubSub → Registry. Mirrors OpenClaw's orderly shutdown.

### Supervision Strategies

| Supervisor | Type | Children | Strategy | Rationale |
|---|---|---|---|---|
| Application | Supervisor | Static | `:one_for_one` | Independent services |
| ToolSupervisor | Task.Supervisor | Ephemeral | `:temporary` | Tools are one-shot; session handles failure |
| SessionSupervisor | DynamicSupervisor | Runtime | `:transient` | Sessions recover from crashes |
| ChannelSupervisor | DynamicSupervisor | Runtime | `:transient` | Channels auto-reconnect |
| CronSupervisor | DynamicSupervisor | Runtime | `:transient` | Cron workers recover and reschedule |

---

## 4. Subsystem Designs

### 4.1 Gateway (Phoenix-based)

**Why Phoenix:** Built-in WebSocket via Channels, PubSub for broadcasts, Presence for connection tracking, battle-tested HTTP.

**Components:**
- `BeamClaw.Gateway.Endpoint` — Phoenix.Endpoint serving HTTP + WS
- `BeamClaw.Gateway.RPCChannel` — Phoenix.Channel implementing OpenClaw's JSON-RPC protocol
- `BeamClaw.NodeRegistry` — GenServer for device pairing/auth

**RPC Channel Protocol Mapping:**

```elixir
defmodule BeamClaw.Gateway.RPCChannel do
  use Phoenix.Channel

  def join("rpc:lobby", %{"deviceId" => device_id}, socket) do
    case BeamClaw.NodeRegistry.authenticate(device_id) do
      {:ok, _} ->
        Phoenix.PubSub.subscribe(BeamClaw.PubSub, "events:global")
        {:ok, assign(socket, :device_id, device_id)}
      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  # Client RPC request → route to handler
  def handle_in("request", %{"id" => id, "method" => method, "params" => params}, socket) do
    result = route_rpc(method, params, socket)
    {:reply, {:ok, %{id: id, result: result}}, socket}
  end

  # Server-pushed events via PubSub
  def handle_info({:push_event, event, data}, socket) do
    push(socket, "event", %{event: event, data: data})
    {:noreply, socket}
  end
end
```

**Event Broadcasting:** All subsystems broadcast via `Phoenix.PubSub.broadcast(BeamClaw.PubSub, "events:global", {:push_event, event, data})`. RPCChannel receives and pushes to WebSocket clients.

### 4.2 Sessions

**Key insight (original design):** Sessions are lightweight metadata holders. Message history lives in the agent runtime process, not the session store.

> **Implementation note (Phase 2, updated Phase 5):** The actual Session GenServer holds `messages: []` (full message history) in its state for simplicity. This is the right tradeoff for single-node Phases 2–5. Message history offloading (to ETS, SQLite, or Postgres) is a Phase 6 concern when state size or distribution becomes relevant. As of Phase 5, the Session state includes `sub_agents`, `monitors`, and `parent_session` fields, implemented via `BeamClaw.Session.SubAgent`.

**State:**

```elixir
%BeamClaw.Session.State{
  # Identity
  session_key: String.t(),          # "agent:ops:main"
  agent_id: String.t(),             # "ops"
  session_id: String.t(),           # "main"

  # Metadata (persisted to JSONL)
  metadata: %{
    updated_at: DateTime.t(),
    channel: %{type: atom(), target: String.t()} | nil,
    skills_snapshot: map() | nil,
    thinking_level: atom(),         # :off | :low | :medium | :high
    verbose_level: atom(),          # :off | :on | :full
    model_override: String.t() | nil,
    provider_override: String.t() | nil
  },

  # Runtime (NOT persisted)
  caller: pid() | nil,              # Who to send responses to
  sub_agents: [pid()],              # Max 1 level deep
  monitors: [reference()],
  parent_session: pid() | nil       # Non-nil = this IS a sub-agent
}
```

**Async Message Flow:**

```elixir
# Channel/Gateway sends message (non-blocking cast)
GenServer.cast(session_pid, {:send_message, message, reply_to: caller_pid})

# Session processes, streams response chunks back
send(caller_pid, {:stream_chunk, session_key, chunk})
send(caller_pid, {:stream_done, session_key, final_response})
```

**Sub-Agent Depth Enforcement:**

```elixir
def handle_call({:spawn_sub_agent, agent_id, opts}, _from, state) do
  if state.parent_session != nil do
    {:reply, {:error, :sub_agents_cannot_spawn}, state}
  else
    {:ok, child} = DynamicSupervisor.start_child(
      BeamClaw.SessionSupervisor,
      {BeamClaw.Session, agent_id: agent_id, parent_session: self()}
    )
    ref = Process.monitor(child)
    {:reply, {:ok, child}, %{state |
      sub_agents: [child | state.sub_agents],
      monitors: [ref | state.monitors]
    }}
  end
end
```

**Persistence:** Atomic write of entire session store per agent.

```elixir
defmodule BeamClaw.Session.Store do
  def save(agent_id, sessions) do
    path = "sessions/#{agent_id}.sessions.jsonl"
    temp = path <> ".tmp"
    content = Enum.map_join(sessions, "\n", &Jason.encode!/1)
    File.write!(temp, content)
    File.rename!(temp, path)
  end
end
```

**Lifecycle:** No idle timeout for regular sessions (they persist forever). Cron-spawned sessions have a 24h cleanup timer.

### 4.3 Providers (Stateless Modules + Finch Pools)

**Why NOT GenServers:** A single GenServer per provider serializes all concurrent requests — bottleneck. Providers are stateless HTTP clients. Finch handles connection pooling and HTTP/2 multiplexing.

```elixir
defmodule BeamClaw.Provider.Anthropic do
  @base_url "https://api.anthropic.com"

  def chat_completion(messages, opts) do
    case check_rate_limit(opts) do
      :ok -> do_request(messages, opts)
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  def stream_chat_completion(messages, opts) do
    stream_to = Keyword.fetch!(opts, :stream_to)

    Task.start(fn ->
      Finch.build(:post, url(), headers(), body(messages, opts))
      |> Finch.stream(BeamClaw.Finch, nil, fn
        {:data, data}, acc ->
          for event <- parse_sse(data) do
            send(stream_to, {:stream_event, event.type, event.data})
          end
          acc
        _, acc -> acc
      end)
      send(stream_to, {:stream_done})
    end)
  end
end
```

**Fallback Chain:** On rate limit or error, try next provider/model.

```elixir
defmodule BeamClaw.Provider do
  def chat_with_fallback(chain, messages, opts) do
    Enum.reduce_while(chain, {:error, :all_failed}, fn {mod, model}, _acc ->
      case mod.chat_completion(messages, Keyword.put(opts, :model, model)) do
        {:ok, resp} -> {:halt, {:ok, resp}}
        {:error, _} -> {:cont, {:error, :failed}}
      end
    end)
  end
end
```

**Rate Limiting:** Track RPM, TPM, and concurrent requests per provider via `:hammer` or ETS counters.

**Usage Stats:** ETS table owned by `BeamClaw.ProviderStats` GenServer. Providers write directly: `:ets.update_counter(:provider_stats, {provider, Date.utc_today()}, [{2, 1}, {3, tokens}], {key, 0, 0})`.

### 4.4 Tools & Background Process Registry

**Execution Modes:**

| Mode | Environment | Security | Implementation |
|------|-------------|----------|----------------|
| Sandbox | Docker container | Isolated FS, network, processes | `System.cmd("docker", ["run", "--rm", ...])` |
| Gateway | Host with restrictions | Env var blocklist, working dir restricted | `Port.open/2` with sanitized env |
| Node | Remote machine | SSH/RPC execution | `:rpc.call(node, ...)` |

**Dangerous Env Var Blocklist:**

```elixir
@blocked ~w[LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES NODE_OPTIONS
            PYTHONPATH RUBYLIB PERL5LIB PATH HOME USER SHELL]
```

**Background Process Registry** (`BeamClaw.BackgroundProcessRegistry`):

Commands that run longer than `yield_after` (default 10s) are registered as background processes. The LLM can later tail output, send stdin, or kill them.

```elixir
%{
  processes: %{
    slug => %{
      port: port(),
      os_pid: integer(),
      command: String.t(),
      started_at: DateTime.t(),
      backgrounded_at: DateTime.t(),
      output_buffer: iodata(),       # Circular, capped at 200KB
      exit_status: integer() | nil
    }
  }
}
```

API: `add_session/4`, `send_input/2`, `tail_output/2`, `mark_exited/2`, `kill_session/1`

**Kill Escalation:**

```elixir
def kill_session(slug) do
  %{os_pid: pid} = get_process(slug)
  System.cmd("kill", ["-TERM", "#{pid}"])           # Graceful
  Process.send_after(self(), {:force_kill, slug}, 5_000)
end

def handle_info({:force_kill, slug}, state) do
  if still_running?(slug) do
    System.cmd("kill", ["-KILL", "#{os_pid}"])      # Force
  end
  {:noreply, state}
end
```

**Tool Approval Flow:** Tools support ask modes (`:off`, `:on_miss`, `:always`). When approval is required, the Session sends `{:approval_request, tool, args}` to the caller (Channel/Gateway) and waits up to 120s for `{:approval_response, :approved | :denied}`.

**PTY Support:** Erlang ports with `:pty` option for interactive shells. **Known limitation:** `Port.close/1` sends SIGHUP, not SIGTERM. Mitigation: use `System.cmd("kill", ...)` for signal control, or `MuonTrap` for managed child processes.

### 4.5 Agent Intelligence Layer (Phase 5)                           ✅ Phase 5

**Skill Loading** (`BeamClaw.Skill`): Filesystem-based, stateless. Scans directories for `SKILL.md` files, parses YAML frontmatter (name, description, tools, prompts). No caching GenServer — skills are read at agent init time. Hot-reload is trivial via Config's FileSystem watcher.

**Agent Configuration** (`BeamClaw.Agent`): A configuration resolver, NOT a process. Given an agent ID, loads config, resolves available skills, and returns an `%Agent{}` struct with model, provider, system prompt, tool allowlist.

**Sub-Agent Spawning** (`BeamClaw.Session.SubAgent`): Enforces OpenClaw's 1-level-deep rule. Parent sessions can spawn sub-agents via `DynamicSupervisor.start_child/2`. Sub-agents have `parent_session: parent_pid` set, which blocks further spawning. Parent monitors sub-agents via `Process.monitor/1` and cleans up on `:DOWN`.

**Tool Approval** (`BeamClaw.Tool.Approval`): ETS-backed approval flow. Three ask modes:
- `:off` — auto-approve all tools
- `:on_miss` — approve once, remember per-session
- `:always` — require approval every invocation

Approval requests broadcast via PubSub (`"approval:SESSION_KEY"`). Any client (LiveView, WebSocket, CLI) can respond. 120s timeout with configurable default (approve/deny).

**Tool Registry** (`BeamClaw.Tool.Registry`): Per-session ETS tool registration. Sessions register available tools at init; tool execution checks the registry for permission. Scoped by session key to prevent cross-session tool leakage.

### 4.6 Channels                                                      ✅ Phase 4

**Behaviour:**

```elixir
defmodule BeamClaw.Channel do
  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback connect(state :: term()) :: {:ok, state :: term()} | {:error, term()}
  @callback handle_inbound(message :: term(), state :: term()) ::
    {:ok, normalized :: map(), state :: term()} | {:error, term()}
  @callback send_message(target :: String.t(), content :: String.t(), state :: term()) ::
    {:ok, state :: term()} | {:error, term()}
  @callback disconnect(state :: term()) :: :ok

  # Optional: channels can register custom RPC methods on the gateway
  @callback gateway_methods() :: [String.t()]
  @optional_callbacks [gateway_methods: 0]
end
```

**Inbound Flow:** Platform event → Channel GenServer → normalize → lookup/create Session → `GenServer.cast(session, {:send_message, msg, reply_to: self()})` → Session streams response → Channel sends to platform API.

**Ecosystem:**

| Platform | Elixir Library | Status |
|----------|---------------|--------|
| Discord | Nostrum | Production-ready (stable Hex releases) |
| Telegram | Telegex, Nadia | Multiple options, needs evaluation |
| Slack | Slack Elixir | Needs evaluation |
| WhatsApp | — | May need custom HTTP client |

### 4.7 Cron (Per-Agent Workers)                                       ✅ Phase 4

One `BeamClaw.Cron.Worker` GenServer per agent, under `BeamClaw.CronSupervisor` (DynamicSupervisor).

**State:**

```elixir
%BeamClaw.Cron.Worker.State{
  agent_id: String.t(),
  jobs: %{
    job_id => %{
      type: :main | :isolated,
      schedule: %{type: :at | :every | :cron, value: term()},
      prompt: String.t(),
      enabled: boolean(),
      consecutive_errors: integer(),
      running_at_ms: integer() | nil,
      next_run: DateTime.t(),
      timer_ref: reference() | nil
    }
  }
}
```

**Timer Flow:** Compute next runs for all jobs → find earliest → `Process.send_after/3` → on wake, execute all due jobs → recompute → reschedule.

**Resilience:**
- Stuck run detection: if `running_at_ms` > 2 hours old, clear it
- Auto-disable: 3 consecutive errors → `enabled: false`
- Restart catchup: missed `every`/`cron` jobs recompute from now; completed one-shot `at` jobs skipped
- Persistence: atomic JSONL writes (temp + rename) per agent

---

## 5. Message Flow

### User → Discord → Session → LLM → Tool → Response → Discord

```
 Discord          Channel.Discord     Session         Provider        Tool
   │                    │                │                │              │
   │── msg ────────────▶│                │                │              │
   │                    │── normalize ──▶│                │              │
   │                    │   cast(:send)  │                │              │
   │                    │                │── stream_chat ─▶│              │
   │                    │                │                │── HTTP/SSE ──▶ Anthropic
   │                    │                │◀─ {:stream_event, delta} ─────│
   │                    │                │◀─ {:stream_event, tool_use} ──│
   │                    │                │                │              │
   │                    │                │── Task.async ────────────────▶│
   │                    │                │                │              │── exec
   │                    │                │◀─ {ref, result} ─────────────│
   │                    │                │                │              │
   │                    │                │── stream_chat ─▶│ (with tool result)
   │                    │                │◀─ {:stream_done, response} ───│
   │                    │                │                │              │
   │                    │◀─ cast(:send) ─│                │              │
   │◀── Discord API ───│                │                │              │
   │                    │                │── PubSub broadcast ──────────▶ Gateway clients
```

**Key properties:**
- Channel never blocks (async cast to session, async cast back)
- Session orchestrates the LLM loop (message → tool → message → done)
- Provider streams SSE events as Erlang messages
- Tools run under Task.Supervisor (crash isolation)
- PubSub decouples event broadcasting from the request path

---

## 6. Process Registry Strategy

**Phase 2-5 (Single Node):** `Registry` only.

```elixir
{Registry, keys: :unique, name: BeamClaw.Registry}

# Keys:
# {:session, session_key} → Session pid
# {:channel, channel_id}  → Channel pid
# {:cron, agent_id}       → Cron.Worker pid
```

**Phase 6 (Multi-Node):** Add `:pg` for distributed discovery. Consider `Horde` for distributed DynamicSupervisor if agent migration is needed.

**Rationale:** Don't prematurely optimize for distribution. Registry is fast and simple. Add complexity only when multi-node is actually implemented.

---

## 7. Error Handling & Fault Tolerance

| Process | Restart | On Crash | Rationale |
|---------|---------|----------|-----------|
| Session | `:transient` | Restart, reload metadata from JSONL | Recover from bugs |
| Channel | `:transient` | Restart, auto-reconnect to platform | Network failures |
| Cron.Worker | `:transient` | Restart, reload jobs, reschedule | Recover from bugs |
| Tool (Task) | `:temporary` | Never restart; Session handles error | One-shot execution |
| Config | `:permanent` | Always restart | Everything depends on it |
| HeartbeatRunner | `:permanent` | Always restart | Core service |

**Tool Retry:** Session-level, not supervisor-level. On transient tool failure, Session retries up to 3 times with exponential backoff before returning error to LLM.

**Circuit Breaker:** Per-provider via `:fuse` library. After N failures in M seconds → open circuit → fail fast → half-open after timeout → test one request.

**Rate Limiting at Gateway:** Limit messages per user per second to prevent mailbox flooding. Use `PlugAttack` or custom Plug.

**Mailbox Overflow Protection:** Monitor `Process.info(self(), :message_queue_len)` in Session GenServer. If > threshold (e.g., 1000), reject new messages with `{:error, :overloaded}`.

---

## 8. State Persistence

### Session Metadata — JSONL (Atomic Writes)

Per-agent file: `sessions/{agent_id}.sessions.jsonl`. Each line = one SessionEntry (metadata only). Written atomically: serialize all → write to temp → `File.rename!/2`.

**Single-writer guarantee:** Only the Session GenServer (or a dedicated persistence process per agent) writes to its agent's file. No concurrent write risk.

### Cron Jobs — JSONL (Atomic Writes)

Per-agent file: `cron/{agent_id}.cron.jsonl`. Same atomic pattern.

### Provider Stats — ETS

In-memory, owned by `BeamClaw.ProviderStats` GenServer. Lost on restart (acceptable for stats).

### Message History — Agent Runtime (In-Memory)

Message history lives in the agent runtime process, not persisted separately by the session system. This matches OpenClaw's architecture. For Phase 5+, consider optional persistence to SQLite/Postgres for analytics.

### Future (Phase 6): Mnesia or Database

For multi-node: Mnesia for distributed session metadata, or Postgres for durable storage with search/analytics.

---

## 9. Configuration Management

**Config Sources:**
1. `config/config.exs` + `config/runtime.exs` — static/env-specific
2. `~/.config/beamclaw/config.yaml` — runtime user config (providers, channels, cron, tools)
3. File watcher — hot-reload on change

**Hot-Reload Safety:**

| Field Category | Hot-Reloadable? | Rationale |
|---|---|---|
| Timeouts, feature flags | Yes | Safe to change at runtime |
| Cron jobs, channel settings | Yes | Workers pick up new config |
| Hooks, skills | Yes | Filesystem-based, stateless |
| API keys, provider URLs | **No — requires restart** | In-flight requests use old values |
| Bind mode, TLS, auth | **No — requires restart** | Structural changes |

**Implementation:** `BeamClaw.Config` GenServer watches file via `FileSystem` hex package. On change: validate → diff → broadcast safe fields via PubSub → log warning for restart-required fields.

---

## 10. Risks & Mitigations

### 10.1 Critical Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| No official Elixir SDKs for Anthropic/OpenAI | Medium | Build with Req/Finch + SSE parsing. Provider behaviour abstracts implementation. Can swap libs. |
| No mature browser automation in Elixir | High | Shell out to Node.js Playwright via Erlang Port. Accept the Node.js dependency for this tool. |
| Erlang ports send SIGHUP, not SIGTERM | Medium | Use `System.cmd("kill", ["-TERM", pid])` for signal control. Evaluate MuonTrap for managed child processes. |
| JSONL won't scale to analytics/multi-node | Low (Phase 2-5) | JSONL is fine for single-node. Plan migration to SQLite/Postgres for Phase 6. |

### 10.2 Ecosystem Gaps

| Component | Node.js (OpenClaw) | Elixir (BeamClaw) | Gap |
|-----------|-------------------|-------------------|-----|
| LLM SDKs | Official (Anthropic, OpenAI) | Community (Anthropix, openai_ex) | No official support, feature lag risk |
| Discord | discord.js (official, mature) | Nostrum (stable on Hex) | Viable, use stable releases |
| Telegram | node-telegram-bot-api (official) | Telegex, Nadia | Multiple options, unclear winner |
| Browser | Playwright (official, Microsoft) | playwright_ex (alpha) | Must shell out to Node.js |
| PTY | node-pty (mature) | Erlang ports (:pty) | Works but signal handling differs |
| Cron parsing | cron-parser | crontab (Hex) | Adequate |

### 10.3 Architecture Risks

| Risk | Mitigation |
|------|------------|
| GenServer state size (large message histories) | Messages live in agent runtime, not session GenServer. Session holds only metadata. |
| Process mailbox overflow (DoS) | Rate limit at gateway. Monitor mailbox length in sessions. |
| Config hot-reload inconsistency | Only reload safe fields. Require restart for critical fields. |
| Distribution split-brain (Phase 6) | Defer to Phase 6. Start single-node. Use `:pg` (AP) not `:global` (CP). |

---

## 11. Where BEAM Wins

### Fault Tolerance is Built-In

OpenClaw has defensive try/catch everywhere. BeamClaw uses supervision trees — if a session crashes, the supervisor restarts it. If a tool hangs, the Task.Supervisor handles it. "Let it crash" eliminates hundreds of lines of error-handling code.

### Process-Per-Task Concurrency

OpenClaw manages Promise pools and concurrency limits for parallel tool execution. BeamClaw spawns a process per tool under Task.Supervisor. Concurrency is the default, not something you opt into.

### Native Message Queuing

OpenClaw would need Bull, BeeQueue, or similar for job queues. BEAM process mailboxes are built-in queues with ordering guarantees.

### Live Production Introspection

```elixir
# Inspect any session's state in production
:sys.get_state(session_pid)

# Trace all messages to a session
:dbg.tracer()
:dbg.p(session_pid, [:m])

# View entire process tree
:observer.start()
```

OpenClaw has limited runtime introspection. BEAM's Observer, tracing, and `:sys` module provide unmatched operational visibility.

### Distribution-Ready

OpenClaw is explicitly single-node. BeamClaw's architecture (Registry + PubSub + DynamicSupervisors) is ready for multi-node clustering via `libcluster` in Phase 6. Agent migration between nodes becomes possible — move a running session from Node A to Node B without dropping connections.

---

## 12. Open Decisions for Phase 2

| Decision | Options | Recommendation |
|----------|---------|----------------|
| Gateway protocol | Replicate OpenClaw's custom protocol vs Phoenix Channels native | Start with Phoenix Channels. Add compatibility adapter later if needed. |
| Provider HTTP library | Req vs Finch directly | Finch for streaming (SSE), Req for simple requests. Both use Finch under the hood. |
| Cron expression parser | `crontab` hex vs custom | `crontab` hex package — mature, well-tested. |
| PTY library | Erlang ports (:pty) vs ExPty vs MuonTrap | Start with Erlang ports. Evaluate MuonTrap if signal handling is problematic. |
| Config format | YAML vs TOML vs Elixir terms | YAML for compatibility with OpenClaw's config format. Use `yaml_elixir` hex. |
| Message history storage | In-memory only vs ETS-backed vs SQLite | In-memory for Phase 2. Evaluate persistence needs in Phase 5. |

---

## 13. Implementation Roadmap

**Phase 2: Core Runtime** — Mix project, Application supervisor, Config loading, Session GenServer, JSONL persistence, basic Anthropic provider (Finch + SSE).

**Phase 3: Gateway & API** — Phoenix Endpoint, RPCChannel, WebSocket protocol, OpenAI-compatible REST endpoints, NodeRegistry + auth.

**Phase 4: Channel System** — Channel behaviour, Discord adapter (Nostrum), message normalization, session routing.

**Phase 5: Agent Features** ✅ — Skill loader (YAML frontmatter), Agent configuration resolver, sub-agent spawning (1-level-deep enforcement), tool approval flow (ask modes + PubSub), tool registry (per-session ETS). Deferred: Tool.Browser (Playwright shim), HeartbeatRunner, ProviderStats.

**Phase 6a: Telemetry & Observability** — `:telemetry` events, LiveDashboard, ProviderStats (ETS), HeartbeatRunner, fault injection tests.

**Phase 6b: Clustering** — `libcluster` for node discovery, `:pg` for distributed registry, distributed PubSub (already supported).

**Phase 6c: Agent Migration & Hot Reload** — Horde for distributed DynamicSupervisor, session state transfer, connection draining, rolling deploys.

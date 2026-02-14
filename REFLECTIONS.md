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

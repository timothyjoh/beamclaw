# Phase Completion Protocol

Run this checklist at the end of every phase.

## 1. Team Delivery
- [ ] All team tasks marked complete
- [ ] Each agent ran `mix compile` before marking done
- [ ] Each agent wrote unit tests for their modules

## 2. Staff Engineer Review (fresh Opus agent)
After team finishes, spin up a NEW CC session with Opus:
```
Prompt: You are a Staff Engineer reviewing BeamClaw Phase N code. Run git diff HEAD~1 to see all changes. Review for: (1) Code quality issues, (2) Missing error handling, (3) Test coverage gaps, (4) Architectural concerns, (5) Anything that doesn't compile or work. Fix any issues you find, then run mix test. Report your findings.
```
- [ ] Staff engineer reviews all phase code
- [ ] Fixes applied and tests pass
- [ ] `mix test` green

## 3. Reflection Agent (fresh Opus agent)  
After staff engineer, spin up ANOTHER new CC session:
```
Prompt: You are a Reflection Agent for BeamClaw. Read PLAN.md, docs/architecture.md, REFLECTIONS.md, and the git log. Answer: (1) What did this phase teach us? (2) Any changes to PLAN.md for future phases? (3) Prompting improvements for next team? (4) Architecture.md updates needed? (5) Any other meta-observations? Append your findings to REFLECTIONS.md.
```
- [ ] Reflection captured in REFLECTIONS.md
- [ ] PLAN.md updated if needed
- [ ] architecture.md updated if needed

## 4. Git
- [ ] `git add -A && git commit -m "Phase N: description"`
- [ ] `git push`

## 5. Documentation
- [ ] Update DECISIONS.md with phase completion + key decisions
- [ ] Capture terminal screenshots for blog post
- [ ] Update memory files

## 6. Report
- [ ] Discord ping to Butter with summary

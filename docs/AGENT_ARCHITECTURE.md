# Shift Agent v12 Agent Architecture

## Goal

Shift Agent should not be a simple calendar insert tool. It should become a user-understanding scheduling agent that:

- reads Google Calendar events,
- understands fixed / flexible / uncertain plans,
- extracts task priority, deadlines, travel time, breaks, and energy cost,
- learns user preferences from dialogue and decisions,
- proposes add/update actions,
- executes only after explicit approval.

## v12 Additions

v12 adds the three core agent features:

1. **Stricter OR-Tools scheduling**
   - The backend no longer relies on Gemini to pick exact times for flexible tasks.
   - Gemini extracts tasks and constraints.
   - OR-Tools CP-SAT places tasks while respecting fixed calendar events, buffer time, travel time, deadlines, target sleep time, and late-night heavy work limits.
   - Tasks are optional in the solver: if everything cannot fit, high-priority tasks are placed first and the rest are returned as unscheduled.

2. **Existing Google Calendar update proposals**
   - Gemini can propose `update_event` actions against visible Google Calendar `event_id`s.
   - Flutter shows before/after, reason, and risk.
   - The user must press approval before `/calendar/update` patches Google Calendar.

3. **pgvector memory search**
   - Scheduling memories are embedded into `memories.embedding`.
   - `/agent/chat` searches similar memories via `match_memories`.
   - Relevant memories are included in the Gemini prompt so the agent can recall user tendencies such as “avoid coding after work” or “prefer larger travel buffers.”
   - If `GEMINI_EMBEDDING_MODEL` is not set, the backend uses a free deterministic hash embedding so the pipeline still works.

## Data Layers

1. **Google Calendar raw events**  
   External source of truth for existing events.

2. **schedule_items**  
   Normalized AI-facing representation. It stores category, item type, fixed/flexible/uncertain, priority, energy, travel, deadline, and whether changes require confirmation.

3. **user_profiles**  
   Stable scheduling defaults, such as target sleep time, buffer minutes, bath time, and confirmation policy.

4. **memories**  
   Extracted user rules, preferences, inferred patterns, and decision learnings. Each memory has confidence, source, evidence, needs_confirmation, and an optional pgvector embedding.

5. **agent_proposals / decision_logs**  
   The agent records what it proposed and whether the user accepted/rejected it. This is the main source for personality learning.

## Agent Pipeline

```text
Flutter AI Chat
  ↓
FastAPI /agent/chat
  ↓
Resolve Google user identity
  ↓
Load Supabase profile + memories
  ↓
pgvector search for memories similar to the current request
  ↓
Sync visible Google Calendar events into schedule_items
  ↓
Extract new memories from user message
  ↓
Gemini extracts tasks, exact events, and possible update actions
  ↓
OR-Tools CP-SAT schedules flexible tasks strictly
  ↓
Backend removes obvious duplicates and stores proposal
  ↓
Flutter shows create/update confirmation cards
  ↓
User approves
  ↓
Google Calendar insert/update + Supabase decision log
```

## Important Safety Rule

The agent must never directly modify Google Calendar without confirmation. It may propose actions, but user approval is required before execution.

## Supabase Migrations

For a fresh database, run:

```text
supabase/migrations/001_agent_schema.sql
```

If you already ran v11’s migration, also run:

```text
supabase/migrations/002_pgvector_memory_search.sql
```

## Future Extensions

- Split long tasks automatically when `can_split=true`.
- Add delete/cancel proposals for uncertain events.
- Add Supabase Auth and RLS policies for production multi-user access.
- Add map-based travel time estimation instead of fixed travel minutes.

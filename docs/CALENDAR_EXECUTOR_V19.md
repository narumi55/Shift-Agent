# Shift Agent v19 CalendarExecutor redesign

This version introduces a single backend calendar execution path.

## New write path

```text
Flutter AI approval / manual operation
  -> POST /calendar/execute
  -> optional Google Calendar refresh
  -> ConflictValidator
  -> Google Calendar create/update/delete
  -> Supabase schedule_items sync
  -> cache_upserts/cache_deletes response
  -> Flutter cache update
```

Flutter should treat `/calendar/insert`, `/calendar/update`, and `/calendar/delete` as development-only compatibility endpoints. Normal UI operations use `/calendar/execute`.

## Why

- AI actions and manual actions now share one safety gate.
- Execution-time validation catches stale cache, missing target event, fixed-event overlap, duplicate create, invalid ranges, and batch conflicts before Google writes.
- Successful Google writes return `cache_upserts` and `cache_deletes`, so Flutter can update its cache without re-reading Google Calendar every chat turn.

## Proposal IDs

`/agent/chat` now generates a `proposal_id` before responding. The same ID is saved in Supabase `agent_proposals`, returned to Flutter, and passed into `/calendar/execute` and `/agent/decision`.

## Execution response

```json
{
  "ok": true,
  "refreshed": false,
  "applied": [],
  "rejected": [],
  "cache_upserts": [],
  "cache_deletes": [],
  "warnings": [],
  "proposal_id": "..."
}
```

-- Shift Agent v19: CalendarExecutor bookkeeping fields.
-- Safe to run after 001_agent_schema.sql on existing projects.

alter table schedule_items add column if not exists completed_at timestamptz;
alter table schedule_items add column if not exists postponed_from_event_id text;
alter table schedule_items add column if not exists last_calendar_action text;

create index if not exists idx_schedule_items_calendar_action
  on schedule_items(user_id, last_calendar_action, updated_at desc);

-- Shift Agent v15: stronger Google Calendar normalization fields.
-- Safe to run after 001_agent_schema.sql on existing projects.

alter table schedule_items add column if not exists google_calendar_id text default 'primary';
alter table schedule_items add column if not exists google_etag text;
alter table schedule_items add column if not exists google_html_link text;
alter table schedule_items add column if not exists raw_title text;
alter table schedule_items add column if not exists normalized_title text;
alter table schedule_items add column if not exists can_shorten boolean default false;
alter table schedule_items add column if not exists is_all_day boolean default false;
alter table schedule_items add column if not exists confidence numeric default 0.7;
alter table schedule_items add column if not exists inferred_by text default 'unknown';
alter table schedule_items add column if not exists last_synced_at timestamptz;

create index if not exists idx_schedule_items_google_event on schedule_items(user_id, google_calendar_id, google_event_id);
create index if not exists idx_schedule_items_type_time on schedule_items(user_id, schedule_type, start_time, end_time);

-- Shift Agent v18: cache/sync safety for Google Calendar operations.
-- Optional but recommended after 001/002/003.

alter table schedule_items add column if not exists deleted_at timestamptz;
alter table schedule_items add column if not exists last_synced_at timestamptz;
alter table schedule_items add column if not exists status text default 'not_started';

create index if not exists idx_schedule_items_sync_state
  on schedule_items(user_id, status, last_synced_at desc);

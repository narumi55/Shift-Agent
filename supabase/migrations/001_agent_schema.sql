-- Shift Agent v11: Supabase schema for a user-understanding scheduling agent.
-- Run this in Supabase SQL Editor.
-- The backend uses SUPABASE_SERVICE_ROLE_KEY, so do not expose that key in Flutter.

create extension if not exists pgcrypto;
create extension if not exists vector;

create table if not exists app_users (
  id uuid primary key,
  google_email text unique,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists user_profiles (
  user_id uuid primary key references app_users(id) on delete cascade,
  target_sleep_time time default '23:30',
  avoid_heavy_work_after time default '22:30',
  default_buffer_minutes int default 10,
  default_meal_minutes int default 30,
  default_bath_minutes int default 25,
  default_sleep_prep_minutes int default 20,
  avoid_tight_schedule boolean default true,
  requires_confirmation_before_changes boolean default true,
  profile_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists schedule_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_users(id) on delete cascade,
  google_event_id text,
  google_calendar_id text default 'primary',
  google_etag text,
  google_html_link text,
  source text not null default 'user_input',
  title text not null,
  raw_title text,
  normalized_title text,
  description text,
  category text default 'other',
  item_type text default 'task', -- event/task/routine/travel/break/buffer
  schedule_type text default 'flexible', -- fixed/flexible/uncertain
  status text default 'not_started',
  start_time timestamptz,
  end_time timestamptz,
  deadline timestamptz,
  duration_minutes int,
  priority text default 'medium',
  importance_score int default 50,
  urgency_score int default 50,
  energy_required text default 'medium',
  mental_load text default 'medium',
  can_split boolean default false,
  location text,
  travel_before_minutes int default 0,
  travel_after_minutes int default 0,
  movable boolean default true,
  can_cancel boolean default false,
  can_shorten boolean default false,
  requires_confirmation boolean default true,
  is_all_day boolean default false,
  confidence numeric default 0.7,
  inferred_by text default 'unknown',
  last_synced_at timestamptz,
  risk_if_missed text,
  notes text,
  raw_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, google_event_id)
);

create table if not exists memories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_users(id) on delete cascade,
  type text not null, -- hard_rule/preference/pattern/constraint/decision_learning
  key text not null,
  value jsonb not null,
  confidence numeric not null default 0.5,
  source text not null default 'conversation',
  evidence text,
  needs_confirmation boolean default false,
  active boolean default true,
  embedding vector(768),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, type, key)
);

create table if not exists conversation_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_users(id) on delete cascade,
  role text not null, -- user/assistant/system
  message text not null,
  extracted_memories jsonb not null default '[]'::jsonb,
  calendar_snapshot jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists agent_proposals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_users(id) on delete cascade,
  status text not null default 'pending', -- pending/accepted/partially_accepted/rejected/expired
  user_message text not null,
  reply text not null,
  proposed_actions jsonb not null default '[]'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  rules_applied jsonb not null default '[]'::jsonb,
  calendar_snapshot jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create table if not exists decision_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_users(id) on delete cascade,
  proposal_id uuid references agent_proposals(id) on delete set null,
  user_action text not null, -- accepted/rejected/partially_accepted
  accepted_json jsonb not null default '[]'::jsonb,
  rejected_json jsonb not null default '[]'::jsonb,
  user_feedback text,
  learned_preferences jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_schedule_items_user_time on schedule_items(user_id, start_time, end_time);
create index if not exists idx_memories_user_active on memories(user_id, active, type, key);
create index if not exists idx_conversation_logs_user_time on conversation_logs(user_id, created_at desc);
create index if not exists idx_agent_proposals_user_status on agent_proposals(user_id, status, created_at desc);

alter table app_users enable row level security;
alter table user_profiles enable row level security;
alter table schedule_items enable row level security;
alter table memories enable row level security;
alter table conversation_logs enable row level security;
alter table agent_proposals enable row level security;
alter table decision_logs enable row level security;

-- The current backend uses the service role key and bypasses RLS.
-- When you move Supabase access into Flutter with Supabase Auth, add policies such as:
-- create policy "users can read own profile" on user_profiles for select using (auth.uid() = user_id);

-- v12 pgvector memory similarity search. Safe to re-run.
create index if not exists idx_memories_embedding_hnsw
  on memories using hnsw (embedding vector_cosine_ops)
  where active = true and embedding is not null;

create or replace function match_memories(
  p_user_id uuid,
  query_embedding vector(768),
  match_count int default 12
)
returns table (
  id uuid,
  user_id uuid,
  type text,
  key text,
  value jsonb,
  confidence numeric,
  source text,
  evidence text,
  needs_confirmation boolean,
  active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  similarity float
)
language sql stable
as $$
  select
    m.id,
    m.user_id,
    m.type,
    m.key,
    m.value,
    m.confidence,
    m.source,
    m.evidence,
    m.needs_confirmation,
    m.active,
    m.created_at,
    m.updated_at,
    1 - (m.embedding <=> query_embedding) as similarity
  from memories m
  where m.user_id = p_user_id
    and m.active = true
    and m.embedding is not null
  order by m.embedding <=> query_embedding
  limit match_count;
$$;

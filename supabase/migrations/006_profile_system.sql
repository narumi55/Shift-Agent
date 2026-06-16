-- Shift Agent v20: profile system, weighted rules, current state, profile review items.
-- Safe to run after existing migrations.

alter table user_profiles add column if not exists target_wake_time time default '08:00';
alter table user_profiles add column if not exists default_planning_mode text default 'balance';

create table if not exists user_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_users(id) on delete cascade,
  key text not null,
  text text not null,
  category text default 'general',
  strength text not null default 'soft', -- hard/strong/soft/hint
  usage text not null default 'always', -- always/on_demand/archived
  source text not null default 'user',
  confidence numeric not null default 0.8,
  evidence text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, key)
);

create table if not exists current_user_state (
  user_id uuid primary key references app_users(id) on delete cascade,
  load_level int not null default 3,
  planning_mode text not null default 'balance',
  energy_level int not null default 3,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists profile_review_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_users(id) on delete cascade,
  title text not null,
  hypothesis text,
  question_text text not null,
  source text not null default 'calendar_analysis',
  evidence text,
  confidence numeric not null default 0.7,
  target_type text not null default 'rule',
  target_action text not null default 'create',
  status text not null default 'pending',
  item_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table memories add column if not exists usage text default 'on_demand';
alter table memories add column if not exists strength text default 'hint';

create index if not exists idx_user_rules_user_active on user_rules(user_id, is_active, usage, strength);
create index if not exists idx_profile_review_items_pending on profile_review_items(user_id, status, created_at desc);

alter table user_rules enable row level security;
alter table current_user_state enable row level security;
alter table profile_review_items enable row level security;

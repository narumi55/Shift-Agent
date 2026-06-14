-- Shift Agent v12: pgvector memory search.
-- Run this after 001_agent_schema.sql if your database was created before v12.

create extension if not exists vector;

alter table memories add column if not exists embedding vector(768);

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

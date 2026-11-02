-- LOCAL TEST ONLY: minimal imitation of the Supabase pieces R4 depends on (plain PostgreSQL 16).
-- NOT part of the migration. Never run on a real Supabase project.
create extension if not exists pgcrypto;
do $$ begin
  create role anon nologin noinherit;
  exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin noinherit; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin noinherit bypassrls; exception when duplicate_object then null; end $$;
do $$ begin create role supabase_admin nologin; exception when duplicate_object then null; end $$;
create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key, aud text, role text, email text,
  raw_app_meta_data jsonb default '{}'::jsonb, raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now());
-- same bodies as Supabase's auth.uid()/auth.jwt()
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim', true), ''),
                  nullif(current_setting('request.jwt.claims', true), ''))::jsonb $$;
grant usage on schema auth, public to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
-- Supabase's default privileges on public (so the migration's REVOKEs are meaningful)
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

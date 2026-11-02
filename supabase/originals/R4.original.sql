-- =============================================================================
-- 0001_saai_core_final_r4.sql  --  SAA'I (ساعي) core schema, FINAL revision 4
--
-- RE-RUNNABLE: safe on an EMPTY project (full build) and on top of an existing r3 database
-- (it only creates what is missing and REPLACES function bodies; no table, column or function is
-- dropped or renamed, no data is touched).  Paste the WHOLE file in the Supabase SQL Editor.
--
-- NOT executed and NOT syntax-checked on PostgreSQL by the author (none available; the one
-- attempt to run it on your Supabase project was not approved).  Run it on a TEST project first
-- and send the exact error text if anything fails.
--
-- EXECUTION ORDER
--   1. This file.                    2. 0001_saai_core_tests_r4.sql (rolls back, leaves nothing).
--   3. First admin (manual, once):   update public.profiles set role='admin' where id='<uuid>';
--   4. External setup (not SQL): the AI worker and, optionally, pg_cron (see the end of this file).
--
-- r4 changes: claim_order also locks the order row; admin_ai_results(only_pending) ignores closed
-- orders; new ai_next_jobs() work queue for the AI worker; GPS purge scheduled with pg_cron (if
-- available); whole file made re-runnable.
-- API note: order_events, order_ai_results, location_access_log use column grants, so clients must
-- SELECT EXPLICIT COLUMNS (select * is denied).
-- =============================================================================

-- Helpers live in a schema that PostgREST must NOT expose (keep it out of
-- Settings > API > Exposed schemas), so they are not callable as API.
create schema if not exists app_private;
grant usage on schema app_private to authenticated, service_role;

-- ---------- Types ------------------------------------------------------------
do $t$ begin
  create type public.user_role as enum ('merchant', 'courier', 'admin');
exception when duplicate_object then null;
end $t$;
do $t$ begin
  create type public.order_status as enum ('available', 'assigned', 'picked', 'transit', 'delivered', 'cancelled', 'exception');
exception when duplicate_object then null;
end $t$;
do $t$ begin
  create type public.ai_review_status as enum ('pending', 'approved', 'auto_approved', 'rejected', 'superseded');
exception when duplicate_object then null;
end $t$;
do $t$ begin
  create type public.classification_status as enum ('unclassified', 'pending', 'approved', 'rejected');
exception when duplicate_object then null;
end $t$;

-- ---------- Pure helpers (no table access) ----------------------------------
create or replace function app_private.text_arr_ok(a text[], max_len int) returns boolean
language sql immutable set search_path = '' as $$
  select not exists (select 1 from unnest(a) x
                     where x is null or btrim(x) = '' or char_length(x) > max_len);
$$;

-- E.164 normaliser. Saudi numbers accept 05xxxxxxxx, 5xxxxxxxx, 9665..., +9665..., 00966...
-- Other countries must already be in international format.  Returns NULL if invalid.
create or replace function app_private.normalize_phone(p text, p_country text) returns text
language plpgsql immutable set search_path = '' as $$
declare s text := regexp_replace(coalesce(p, ''), '[\s\-()]', '', 'g');
begin
  if s ~ '^00' then s := '+' || substr(s, 3); end if;
  if p_country = 'SA' and s !~ '^\+' then
    if    s ~ '^966'          then s := '+' || s;
    elsif s ~ '^0?5[0-9]{8}$' then s := '+966' || regexp_replace(s, '^0', '');
    end if;
  end if;
  if p_country = 'SA' and s !~ '^\+9665[0-9]{8}$' then return null; end if;
  if s !~ '^\+[1-9][0-9]{7,14}$' then return null; end if;
  return s;
end;
$$;

-- ---------- Geography (expandable beyond Saudi Arabia) ----------------------
create table if not exists public.countries (
  code        char(2) primary key check (code = upper(code)),
  name_ar     text not null,
  name_en     text not null,
  phone_code  text not null check (phone_code ~ '^\+[0-9]{1,4}$'),
  currency    char(3) not null check (currency = upper(currency)),
  timezone    text not null,
  min_lat double precision, max_lat double precision,
  min_lng double precision, max_lng double precision,
  active      boolean not null default true
);

create table if not exists public.cities (
  id           uuid primary key default gen_random_uuid(),
  country_code char(2) not null references public.countries (code),
  slug         text not null check (slug ~ '^[a-z0-9-]+$'),
  name_ar      text not null,
  name_en      text not null,
  timezone     text,
  active       boolean not null default true,
  unique (country_code, slug)
);

insert into public.countries
  (code, name_ar, name_en, phone_code, currency, timezone, min_lat, max_lat, min_lng, max_lng)
values ('SA', 'المملكة العربية السعودية', 'Saudi Arabia', '+966', 'SAR', 'Asia/Riyadh', 16, 33, 34, 56)
on conflict (code) do nothing;

insert into public.cities (country_code, slug, name_ar, name_en) values
  ('SA', 'riyadh',  'الرياض',          'Riyadh'),
  ('SA', 'jeddah',  'جدة',             'Jeddah'),
  ('SA', 'dammam',  'الدمام',          'Dammam'),
  ('SA', 'makkah',  'مكة المكرمة',     'Makkah'),
  ('SA', 'madinah', 'المدينة المنورة', 'Madinah'),
  ('SA', 'khobar',  'الخبر',           'Al Khobar')
on conflict (country_code, slug) do nothing;

-- ---------- Settings (single-row tables) ------------------------------------
create table if not exists public.priority_rules (
  id               boolean primary key default true check (id),
  critical_hours   numeric(5,1) not null default 2,
  high_hours       numeric(5,1) not null default 6,
  normal_hours     numeric(5,1) not null default 48,
  aging_hours      numeric(5,1) not null default 24,
  handling_raises  boolean      not null default true,
  fragile_min_level     smallint not null default 1 check (fragile_min_level     between 0 and 2),
  temperature_min_level smallint not null default 2 check (temperature_min_level between 0 and 2),
  health_min_level      smallint not null default 2 check (health_min_level      between 0 and 2),
  updated_at       timestamptz  not null default now(),
  constraint priority_rules_order check
    (critical_hours > 0 and critical_hours < high_hours
     and high_hours < normal_hours and aging_hours > 0)
);
insert into public.priority_rules default values on conflict do nothing;

create table if not exists public.ai_settings (
  id boolean primary key default true check (id),
  -- NULL (default) = the server NEVER auto-approves; every result waits for an admin.
  auto_approve_threshold numeric(3,2) check (auto_approve_threshold between 0.5 and 1),
  updated_at timestamptz not null default now()
);
insert into public.ai_settings default values on conflict do nothing;

-- ---------- People -----------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  role       public.user_role not null default 'merchant',
  full_name  text not null default '' check (char_length(full_name) <= 120),
  name_ar    text check (name_ar is null or char_length(name_ar) <= 120),
  name_en    text check (name_en is null or char_length(name_en) <= 120),
  phone      text check (phone is null or phone ~ '^\+?[0-9]{9,15}$'),
  city_id    uuid references public.cities (id),
  lang       text not null default 'ar' check (lang in ('ar', 'en')),
  theme      text check (theme is null or theme in ('light', 'dark')),
  calendar   text not null default 'gregorian' check (calendar in ('gregorian', 'hijri')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists profiles_role_idx on public.profiles (role);

create table if not exists public.merchants (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null unique references public.profiles (id) on delete cascade,
  name       text not null check (char_length(btrim(name)) between 1 and 120),
  city_id    uuid references public.cities (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.merchant_contacts (
  merchant_id uuid primary key references public.merchants (id) on delete cascade,
  phone       text not null check (phone ~ '^\+[1-9][0-9]{7,14}$')
);

create table if not exists public.courier_profiles (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  vehicle     text check (vehicle is null or char_length(vehicle) <= 60),
  available   boolean not null default false,
  approved    boolean not null default false,
  approved_at timestamptz,
  approved_by uuid references public.profiles (id) on delete set null,
  location_consent_at timestamptz,            -- set only through set_location_consent()
  created_at  timestamptz not null default now(),
  constraint courier_available_requires_approval check (not available or approved)
);

-- ---------- Orders -----------------------------------------------------------
create sequence if not exists public.order_ref_seq start 24200;

create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  ref           text not null unique default ('SA-' || nextval('public.order_ref_seq')::text),
  merchant_id   uuid not null references public.merchants (id) on delete restrict,
  merchant_name text not null,                         -- snapshot at creation (couriers never read merchants)
  created_by    uuid not null references public.profiles (id),
  courier_id    uuid references public.profiles (id) on delete set null,
  status        public.order_status not null default 'available',

  items         text[] not null check (cardinality(items) between 1 and 50 and app_private.text_arr_ok(items, 200)),
  categories    text[] not null default '{}' check (cardinality(categories) <= 10 and app_private.text_arr_ok(categories, 40)),
  classification_status public.classification_status not null default 'unclassified',

  pickup_city_id   uuid not null references public.cities (id),
  pickup_district  text not null check (char_length(btrim(pickup_district)) between 1 and 120),
  pickup_lat       double precision,
  pickup_lng       double precision,
  dropoff_city_id  uuid not null references public.cities (id),
  dropoff_district text not null check (char_length(btrim(dropoff_district)) between 1 and 120),
  dropoff_lat      double precision,
  dropoff_lng      double precision,

  deadline_at   timestamptz,
  handling_fragile     boolean not null default false,
  handling_temperature boolean not null default false,
  handling_health      boolean not null default false,

  priority_override smallint check (priority_override between 0 and 3),
  currency          char(3) not null default 'SAR',

  cancel_reason  text check (cancel_reason is null or char_length(cancel_reason) <= 300),
  exception_note text check (exception_note is null or char_length(exception_note) <= 500),

  created_at   timestamptz not null default now(),
  claimed_at   timestamptz,
  picked_at    timestamptz,
  delivered_at timestamptz,
  updated_at   timestamptz not null default now(),

  constraint orders_pickup_coords  check ((pickup_lat is null) = (pickup_lng is null)),
  constraint orders_dropoff_coords check ((dropoff_lat is null) = (dropoff_lng is null)),
  constraint orders_pickup_range   check (pickup_lat  is null or (pickup_lat  between -90 and 90 and pickup_lng  between -180 and 180)),
  constraint orders_dropoff_range  check (dropoff_lat is null or (dropoff_lat between -90 and 90 and dropoff_lng between -180 and 180)),
  constraint orders_available_has_no_courier check (status <> 'available' or courier_id is null),
  constraint orders_active_has_courier check
    (status not in ('assigned', 'picked', 'transit', 'delivered') or courier_id is not null)
);
create index if not exists orders_available_idx on public.orders (created_at)         where status = 'available';
create index if not exists orders_courier_idx   on public.orders (courier_id, status)  where courier_id is not null;
create index if not exists orders_merchant_idx  on public.orders (merchant_id, created_at desc);
create index if not exists orders_deadline_idx  on public.orders (deadline_at)
  where status in ('available', 'assigned', 'picked', 'transit') and deadline_at is not null;
create index if not exists orders_status_idx    on public.orders (status, created_at desc);
create index if not exists orders_unclassified_idx on public.orders (created_at)
  where classification_status in ('unclassified', 'pending');
create index if not exists orders_created_by_idx on public.orders (created_by);
-- A courier can hold at most ONE active order.  This is the real guarantee: even two
-- simultaneous claims by the same courier cannot both commit.
create unique index if not exists orders_one_active_per_courier on public.orders (courier_id)
  where courier_id is not null and status in ('assigned', 'picked', 'transit');

-- Courier pay lives apart from orders: merchants must never read it.
create table if not exists public.order_fees (
  order_id   uuid primary key references public.orders (id) on delete cascade,
  amount     numeric(8,2) not null check (amount >= 0),
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.order_recipients (
  order_id uuid primary key references public.orders (id) on delete cascade,
  name     text not null check (char_length(btrim(name)) between 1 and 120),
  phone    text not null check (phone ~ '^\+[1-9][0-9]{7,14}$')
);

create table if not exists public.order_events (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references public.orders (id) on delete cascade,
  actor_id    uuid references public.profiles (id) on delete set null,
  kind        text not null,
  from_status public.order_status,
  to_status   public.order_status,
  details     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists order_events_order_idx on public.order_events (order_id, created_at);

create table if not exists public.order_ai_results (
  id                   uuid primary key default gen_random_uuid(),
  order_id             uuid not null references public.orders (id) on delete cascade,
  version              int  not null check (version > 0),
  source               text not null check (source in ('local_rules', 'server_model', 'admin_manual')),
  model                text check (model is null or char_length(model) <= 100),
  input_items          text[] not null default '{}',
  suggested_categories text[] not null check (cardinality(suggested_categories) <= 10 and app_private.text_arr_ok(suggested_categories, 40)),
  confidence           numeric(3,2) check (confidence between 0 and 1),
  reason               text check (reason is null or char_length(reason) <= 500),
  needs_verification   boolean not null default false,
  review_status        public.ai_review_status not null default 'pending',
  final_categories     text[] check (final_categories is null or (cardinality(final_categories) between 1 and 10 and app_private.text_arr_ok(final_categories, 40))),
  reviewed_by          uuid references public.profiles (id) on delete set null,
  reviewed_at          timestamptz,
  review_note          text check (review_note is null or char_length(review_note) <= 500),
  created_at           timestamptz not null default now(),
  unique (order_id, version),
  constraint ai_final_iff_approved check
    ((review_status in ('approved', 'auto_approved')) = (final_categories is not null))
);
create index if not exists order_ai_results_pending_idx on public.order_ai_results (created_at)
  where review_status = 'pending';

create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  kind       text not null,
  order_id   uuid references public.orders (id) on delete cascade,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists notifications_user_idx   on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications (user_id) where read_at is null;

-- ---------- Courier location (privacy-minimised) ----------------------------
create table if not exists public.courier_locations_latest (
  courier_id uuid primary key references public.profiles (id) on delete cascade,
  order_id   uuid references public.orders (id) on delete set null,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  accuracy_m  numeric(7,1) check (accuracy_m  is null or accuracy_m  >= 0),
  heading_deg numeric(5,1) check (heading_deg is null or heading_deg between 0 and 360),
  speed_mps   numeric(6,2) check (speed_mps   is null or speed_mps   between 0 and 100),
  recorded_at timestamptz not null,
  updated_at  timestamptz not null default now()
);

create index if not exists courier_loc_latest_order_idx on public.courier_locations_latest (order_id);

create table if not exists public.courier_location_history (
  id          bigint generated always as identity primary key,
  courier_id  uuid not null references public.profiles (id) on delete cascade,
  order_id    uuid references public.orders (id) on delete set null,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  accuracy_m  numeric(7,1) check (accuracy_m is null or accuracy_m >= 0),
  recorded_at timestamptz not null,
  created_at  timestamptz not null default now()
);
create index if not exists courier_loc_hist_courier_idx on public.courier_location_history (courier_id, recorded_at desc);
create index if not exists courier_loc_hist_order_idx   on public.courier_location_history (order_id, recorded_at);
create index if not exists courier_loc_hist_purge_idx   on public.courier_location_history (recorded_at);

-- Who looked at a courier's location (admins only are logged; the courier can read it).
create table if not exists public.location_access_log (
  id         bigint generated always as identity primary key,
  viewer_id  uuid references public.profiles (id) on delete set null,
  courier_id uuid not null references public.profiles (id) on delete cascade,
  order_id   uuid references public.orders (id) on delete set null,
  kind       text not null check (kind in ('live', 'history')),
  created_at timestamptz not null default now()
);
create index if not exists location_access_log_courier_idx on public.location_access_log (courier_id, created_at desc);

-- ---------- Private helpers (table-aware) ------------------------------------
create or replace function app_private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                 where p.id = (select auth.uid()) and p.role = 'admin');
$$;

create or replace function app_private.is_approved_courier() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.courier_profiles cp
                 join public.profiles p on p.id = cp.user_id
                 where cp.user_id = (select auth.uid()) and cp.approved and p.role = 'courier');
$$;

create or replace function app_private.owns_merchant(p_merchant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.merchants m
                 where m.id = p_merchant and m.owner_id = (select auth.uid()));
$$;

-- Merchant phone: only for a courier currently working an order of that merchant.
create or replace function app_private.courier_works_for_merchant(p_merchant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.orders o
                 where o.merchant_id = p_merchant and o.courier_id = (select auth.uid())
                   and o.status in ('assigned', 'picked', 'transit'));
$$;

-- Events: the viewer owns the order's merchant, or is the CURRENTLY assigned courier.
create or replace function app_private.can_view_order_events(p_order uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.orders o
                 where o.id = p_order
                   and (o.courier_id = (select auth.uid())
                        or exists (select 1 from public.merchants m
                                   where m.id = o.merchant_id and m.owner_id = (select auth.uid()))));
$$;

-- True for the Edge Function (service_role JWT) or a direct trusted DB session
-- (SQL editor / CLI as postgres).  Never true for an app user going through the API.
create or replace function app_private.is_server() returns boolean
language sql stable set search_path = '' as $$
  select coalesce((select auth.jwt()) ->> 'role', '') = 'service_role'
      or session_user in ('postgres', 'supabase_admin');
$$;

-- Priority 0..3 = low, normal, high, critical, plus JSON reasons.
-- Codes: override | no_deadline | deadline_far | deadline_normal | deadline_high | deadline_critical
--        handling_fragile | handling_temperature | handling_health (applied=raised the level) | aging
create or replace function app_private.priority_details(o public.orders, out lvl smallint, out reasons jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare
  r  public.priority_rules;
  l  int := 0;
  ld int := 0;
  h  numeric;
  wh numeric;
  a  int;
  nl int;
  rs jsonb := '[]'::jsonb;
begin
  if o.priority_override is not null then
    lvl := o.priority_override;
    reasons := jsonb_build_array(jsonb_build_object('code', 'override', 'level', o.priority_override));
    return;
  end if;
  select * into r from public.priority_rules limit 1;

  if o.deadline_at is null then
    rs := rs || jsonb_build_array(jsonb_build_object('code', 'no_deadline', 'level', 0));
  else
    h := extract(epoch from (o.deadline_at - now())) / 3600.0;
    if h <= r.critical_hours then
      ld := 3; rs := rs || jsonb_build_array(jsonb_build_object('code', 'deadline_critical', 'level', 3, 'hours_left', round(greatest(h, 0), 1)));
    elsif h <= r.high_hours then
      ld := 2; rs := rs || jsonb_build_array(jsonb_build_object('code', 'deadline_high', 'level', 2, 'hours_left', round(h, 1)));
    elsif h <= r.normal_hours then
      ld := 1; rs := rs || jsonb_build_array(jsonb_build_object('code', 'deadline_normal', 'level', 1, 'hours_left', round(h, 1)));
    else
      rs := rs || jsonb_build_array(jsonb_build_object('code', 'deadline_far', 'level', 0, 'hours_left', round(h, 1)));
    end if;
  end if;

  l := ld;
  if r.handling_raises then
    if o.handling_fragile then
      rs := rs || jsonb_build_array(jsonb_build_object('code', 'handling_fragile', 'level', r.fragile_min_level, 'applied', r.fragile_min_level > ld));
      l := greatest(l, r.fragile_min_level);
    end if;
    if o.handling_temperature then
      rs := rs || jsonb_build_array(jsonb_build_object('code', 'handling_temperature', 'level', r.temperature_min_level, 'applied', r.temperature_min_level > ld));
      l := greatest(l, r.temperature_min_level);
    end if;
    if o.handling_health then
      rs := rs || jsonb_build_array(jsonb_build_object('code', 'handling_health', 'level', r.health_min_level, 'applied', r.health_min_level > ld));
      l := greatest(l, r.health_min_level);
    end if;
  end if;

  if o.status = 'available' and l < 2 then
    wh := floor(extract(epoch from (now() - o.created_at)) / 3600.0);
    a  := floor(wh / r.aging_hours);
    if a > 0 then
      nl := least(2, l + a);
      rs := rs || jsonb_build_array(jsonb_build_object('code', 'aging', 'waited_hours', wh, 'levels', nl - l));
      l := nl;
    end if;
  end if;

  lvl := l::smallint;
  reasons := rs;
end;
$$;

-- ---------- Views (security_invoker => caller's RLS and column grants apply) -
create or replace view public.orders_prioritized with (security_invoker = true) as
  select o.*, pd.lvl as priority, pd.reasons as priority_reasons, f.amount as courier_fee
  from public.orders o
  cross join lateral app_private.priority_details(o) pd
  left join public.order_fees f on f.order_id = o.id;

-- Latest AI result per order, ONLY the columns merchants may see
-- (no model, no input snapshot, no reviewer id, no internal review note).
create or replace view public.order_ai_current with (security_invoker = true) as
  select distinct on (r.order_id)
         r.id, r.order_id, r.version, r.source, r.suggested_categories, r.confidence, r.reason,
         r.needs_verification, r.review_status, r.final_categories, r.reviewed_at, r.created_at
  from public.order_ai_results r
  order by r.order_id, r.version desc;

-- ---------- Triggers ---------------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end;
$$;
create or replace trigger profiles_touch    before update on public.profiles       for each row execute function public.touch_updated_at();
create or replace trigger merchants_touch   before update on public.merchants      for each row execute function public.touch_updated_at();
create or replace trigger rules_touch       before update on public.priority_rules for each row execute function public.touch_updated_at();
create or replace trigger ai_settings_touch before update on public.ai_settings    for each row execute function public.touch_updated_at();

create or replace function public.orders_validate_location() returns trigger
language plpgsql set search_path = '' as $$
declare p record; d record;
begin
  select ci.active as c_active, co.active as k_active, co.code, co.currency,
         co.min_lat, co.max_lat, co.min_lng, co.max_lng
    into p from public.cities ci join public.countries co on co.code = ci.country_code
   where ci.id = new.pickup_city_id;
  select ci.active as c_active, co.active as k_active, co.code
    into d from public.cities ci join public.countries co on co.code = ci.country_code
   where ci.id = new.dropoff_city_id;

  if p is null or d is null or not (p.c_active and p.k_active and d.c_active and d.k_active) then
    raise exception 'city_not_available' using errcode = 'P0001';
  end if;
  if p.code <> d.code then
    raise exception 'cross_border_not_supported' using errcode = 'P0001';
  end if;
  if new.pickup_lat is not null and p.min_lat is not null
     and not (new.pickup_lat between p.min_lat and p.max_lat and new.pickup_lng between p.min_lng and p.max_lng) then
    raise exception 'pickup_outside_country' using errcode = 'P0001';
  end if;
  if new.dropoff_lat is not null and p.min_lat is not null
     and not (new.dropoff_lat between p.min_lat and p.max_lat and new.dropoff_lng between p.min_lng and p.max_lng) then
    raise exception 'dropoff_outside_country' using errcode = 'P0001';
  end if;
  new.currency := p.currency;
  return new;
end;
$$;
create or replace trigger orders_validate_location_trg
  before insert or update of pickup_city_id, dropoff_city_id, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng
  on public.orders for each row execute function public.orders_validate_location();

-- STATE MACHINE + immutability + system-managed timestamps (one trigger => deterministic order).
--   available -> assigned | cancelled
--   assigned  -> picked | available | cancelled | exception        (assigned -> assigned = reassignment)
--   picked    -> transit | cancelled | exception
--   transit   -> delivered | cancelled | exception
--   exception -> assigned | available | cancelled
--   delivered, cancelled -> terminal
-- The courier may change only while the new status is 'available' or 'assigned'.
create or replace function public.orders_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id <> old.id or new.ref <> old.ref or new.merchant_id <> old.merchant_id
     or new.merchant_name <> old.merchant_name or new.created_by <> old.created_by
     or new.created_at <> old.created_at or new.items <> old.items then
    raise exception 'immutable_column' using errcode = '42501';
  end if;
  if new.claimed_at   is distinct from old.claimed_at
     or new.picked_at    is distinct from old.picked_at
     or new.delivered_at is distinct from old.delivered_at then
    raise exception 'timestamps_are_system_managed' using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    if not (   (old.status = 'available' and new.status in ('assigned', 'cancelled'))
            or (old.status = 'assigned'  and new.status in ('picked', 'available', 'cancelled', 'exception'))
            or (old.status = 'picked'    and new.status in ('transit', 'cancelled', 'exception'))
            or (old.status = 'transit'   and new.status in ('delivered', 'cancelled', 'exception'))
            or (old.status = 'exception' and new.status in ('assigned', 'available', 'cancelled'))) then
      raise exception 'invalid_status_transition' using errcode = 'P0001',
        detail = old.status::text || ' -> ' || new.status::text;
    end if;
    if new.status = 'assigned' then
      new.claimed_at := now(); new.picked_at := null; new.delivered_at := null; new.exception_note := null;
    elsif new.status = 'available' then
      new.claimed_at := null; new.picked_at := null; new.delivered_at := null; new.exception_note := null;
    elsif new.status = 'picked'    then new.picked_at    := now();
    elsif new.status = 'delivered' then new.delivered_at := now();
    end if;
  elsif new.courier_id is distinct from old.courier_id then
    if new.status <> 'assigned' then
      raise exception 'courier_change_not_allowed' using errcode = 'P0001';
    end if;
    new.claimed_at := now();
  end if;

  if new.courier_id is distinct from old.courier_id and new.status not in ('available', 'assigned') then
    raise exception 'courier_change_not_allowed' using errcode = 'P0001';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create or replace trigger orders_guard_trg before update on public.orders
  for each row execute function public.orders_guard();

create or replace function public.orders_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := (select auth.uid());
  v_owner uuid;
begin
  select m.owner_id into v_owner from public.merchants m where m.id = new.merchant_id;

  if tg_op = 'INSERT' then
    insert into public.order_events (order_id, actor_id, kind, to_status)
    values (new.id, v_actor, 'created', new.status);
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.order_events (order_id, actor_id, kind, from_status, to_status)
    values (new.id, v_actor, 'status_changed', old.status, new.status);
    if v_owner is not null and v_owner is distinct from v_actor then
      insert into public.notifications (user_id, kind, order_id)
      values (v_owner, 'order_' || new.status::text, new.id);
    end if;
    if new.status = 'exception' then
      insert into public.notifications (user_id, kind, order_id)
      select p.id, 'order_exception', new.id from public.profiles p
      where p.role = 'admin' and p.id is distinct from v_actor;
    end if;
    if new.status = 'cancelled' and old.courier_id is not null
       and old.courier_id is distinct from v_actor then
      insert into public.notifications (user_id, kind, order_id)
      values (old.courier_id, 'order_cancelled', new.id);
    end if;
  end if;

  if new.courier_id is distinct from old.courier_id then
    insert into public.order_events (order_id, actor_id, kind, details)
    values (new.id, v_actor, 'courier_changed',
            jsonb_build_object('from', old.courier_id, 'to', new.courier_id));
    if old.courier_id is not null and old.courier_id is distinct from v_actor then
      insert into public.notifications (user_id, kind, order_id)
      values (old.courier_id, 'order_unassigned', new.id);
    end if;
    if new.courier_id is not null and new.courier_id is distinct from v_actor then
      insert into public.notifications (user_id, kind, order_id)
      values (new.courier_id, 'order_assigned', new.id);
    end if;
  end if;

  if new.priority_override is distinct from old.priority_override then
    insert into public.order_events (order_id, actor_id, kind, details)
    values (new.id, v_actor, 'priority_override',
            jsonb_build_object('from', old.priority_override, 'to', new.priority_override));
  end if;
  return new;
end;
$$;
create or replace trigger orders_audit_trg after insert or update on public.orders
  for each row execute function public.orders_audit();

create or replace function public.release_courier_location() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.courier_id is not null
     and (new.status is distinct from old.status or new.courier_id is distinct from old.courier_id)
     and not exists (select 1 from public.orders o
                     where o.courier_id = old.courier_id
                       and o.status in ('assigned', 'picked', 'transit')) then
    delete from public.courier_locations_latest where courier_id = old.courier_id;
  end if;
  return new;
end;
$$;
create or replace trigger orders_release_location_trg after update on public.orders
  for each row execute function public.release_courier_location();

-- ----- AI: order state is RECOMPUTED from the results, never patched by the latest event -----
-- Order state is RECOMPUTED from the results, never patched by the latest event.
-- Only results whose input_items equal the order's CURRENT items count (stale input ignored).
--  status:     newest result pending -> 'pending'; approved -> 'approved';
--              rejected -> 'approved' if an earlier approval exists (kept), else 'rejected'
--  categories: those of the NEWEST approved result ('{}' if none)
create or replace function public.ai_recompute_order(p_order uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_items text[]; v_latest public.ai_review_status; v_has_ok boolean; v_cats text[];
begin
  select o.items into v_items from public.orders o where o.id = p_order;
  if not found then return; end if;

  select r.review_status into v_latest from public.order_ai_results r
   where r.order_id = p_order and r.review_status <> 'superseded' and r.input_items = v_items
   order by r.version desc limit 1;
  select true, r.final_categories into v_has_ok, v_cats from public.order_ai_results r
   where r.order_id = p_order and r.review_status in ('approved', 'auto_approved')
     and r.input_items = v_items
   order by r.version desc limit 1;

  update public.orders
     set classification_status = case
           when v_latest is null then 'unclassified'::public.classification_status
           when v_latest = 'pending' then 'pending'
           when v_latest in ('approved', 'auto_approved') then 'approved'
           when coalesce(v_has_ok, false) then 'approved'
           else 'rejected' end,
         categories = coalesce(v_cats, '{}')
   where id = p_order;
end;
$$;

create or replace function public.ai_results_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid;
begin
  if new.review_status = 'superseded' then return new; end if;

  if tg_op = 'INSERT' then
    update public.order_ai_results set review_status = 'superseded'
     where order_id = new.order_id and id <> new.id and review_status = 'pending';
    insert into public.order_events (order_id, actor_id, kind, details)
    values (new.order_id, (select auth.uid()), 'ai_recorded',
            jsonb_build_object('source', new.source, 'version', new.version, 'status', new.review_status));
    if new.review_status = 'pending' then
      insert into public.notifications (user_id, kind, order_id)
      select p.id, 'ai_review_needed', new.order_id from public.profiles p where p.role = 'admin';
    end if;
  else
    insert into public.order_events (order_id, actor_id, kind, details)
    values (new.order_id, (select auth.uid()), 'ai_reviewed',
            jsonb_build_object('version', new.version, 'status', new.review_status));
    select m.owner_id into v_owner from public.orders o join public.merchants m on m.id = o.merchant_id
     where o.id = new.order_id;
    if v_owner is not null then
      insert into public.notifications (user_id, kind, order_id)
      values (v_owner, 'ai_reviewed', new.order_id);
    end if;
  end if;

  perform public.ai_recompute_order(new.order_id);
  return new;
end;
$$;
create or replace trigger order_ai_results_sync_ins after insert on public.order_ai_results
  for each row execute function public.ai_results_sync();
create or replace trigger order_ai_results_sync_upd after update of review_status on public.order_ai_results
  for each row when (old.review_status is distinct from new.review_status)
  execute function public.ai_results_sync();

-- Results are append-only; only the review fields (and 'superseded') may change, once.
create or replace function public.ai_results_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.order_id <> old.order_id or new.version <> old.version or new.source <> old.source
     or new.model is distinct from old.model or new.input_items <> old.input_items
     or new.suggested_categories <> old.suggested_categories
     or new.confidence is distinct from old.confidence
     or new.reason is distinct from old.reason
     or new.needs_verification <> old.needs_verification
     or new.created_at <> old.created_at then
    raise exception 'immutable_column' using errcode = '42501';
  end if;
  -- approved / auto_approved / rejected / superseded are final.  The only change still allowed is
  -- the FK action "reviewed_by -> NULL" when the reviewing admin's account is deleted.
  if old.review_status <> 'pending'
     and not (new.review_status = old.review_status
              and new.final_categories is not distinct from old.final_categories
              and new.reviewed_at is not distinct from old.reviewed_at
              and new.review_note is not distinct from old.review_note
              and new.reviewed_by is null) then
    raise exception 'result_already_final' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create or replace trigger order_ai_results_guard_trg before update on public.order_ai_results
  for each row execute function public.ai_results_guard();

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_role public.user_role :=
    case when new.raw_user_meta_data ->> 'role' = 'courier'
         then 'courier'::public.user_role else 'merchant'::public.user_role end;
begin
  insert into public.profiles (id, role, full_name)
  values (new.id, v_role, left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 120));
  if v_role = 'merchant' then
    insert into public.merchants (owner_id, name)
    values (new.id, left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'store_name'), ''), 'متجر جديد'), 120));
  else
    insert into public.courier_profiles (user_id) values (new.id);
  end if;
  return new;
end;
$$;
create or replace trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- RPC: orders (the ONLY write path; there is no direct UPDATE on orders) -------
-- Merchants create an order + recipient atomically.  No AI / categories / priority / fee
-- parameters exist on purpose.  Limits are checked while holding the merchant's row lock,
-- so parallel requests cannot slip past them: max 200 orders per hour, 300 open (available).
create or replace function public.create_order(
  p_merchant uuid, p_recipient_name text, p_recipient_phone text,
  p_items text[],
  p_pickup_city uuid, p_pickup_district text,
  p_dropoff_city uuid, p_dropoff_district text,
  p_pickup_lat double precision default null, p_pickup_lng double precision default null,
  p_dropoff_lat double precision default null, p_dropoff_lng double precision default null,
  p_deadline timestamptz default null,
  p_fragile boolean default false, p_temperature boolean default false, p_health boolean default false
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_country text; v_phone text; v_name text; v_hour int; v_open int;
begin
  if (select auth.uid()) is null or not app_private.owns_merchant(p_merchant) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select m.name into v_name from public.merchants m where m.id = p_merchant for update;  -- per-merchant lock
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;

  select count(*) into v_hour from public.orders o
   where o.merchant_id = p_merchant and o.created_at > now() - interval '1 hour';
  select count(*) into v_open from public.orders o
   where o.merchant_id = p_merchant and o.status = 'available';
  if v_hour >= 200 then raise exception 'rate_limited' using errcode = 'P0001'; end if;
  if v_open >= 300 then raise exception 'too_many_open_orders' using errcode = 'P0001'; end if;

  if p_deadline is not null and p_deadline < now() - interval '5 minutes' then
    raise exception 'deadline_in_past' using errcode = 'P0001';
  end if;
  if p_deadline is not null and p_deadline > now() + interval '90 days' then
    raise exception 'deadline_too_far' using errcode = 'P0001';
  end if;
  select ci.country_code into v_country from public.cities ci where ci.id = p_dropoff_city;
  v_phone := app_private.normalize_phone(p_recipient_phone, v_country);
  if v_phone is null then raise exception 'invalid_phone' using errcode = 'P0001'; end if;

  insert into public.orders (
    merchant_id, merchant_name, created_by, items,
    pickup_city_id, pickup_district, pickup_lat, pickup_lng,
    dropoff_city_id, dropoff_district, dropoff_lat, dropoff_lng,
    deadline_at, handling_fragile, handling_temperature, handling_health)
  values (
    p_merchant, v_name, (select auth.uid()), p_items,
    p_pickup_city, p_pickup_district, p_pickup_lat, p_pickup_lng,
    p_dropoff_city, p_dropoff_district, p_dropoff_lat, p_dropoff_lng,
    p_deadline, coalesce(p_fragile, false), coalesce(p_temperature, false), coalesce(p_health, false))
  returning * into v_order;

  insert into public.order_recipients (order_id, name, phone)
  values (v_order.id, btrim(p_recipient_name), v_phone);
  return v_order;
end;
$$;

-- Two couriers can never both win.  (1) the courier's own row is locked (serialises with
-- approve_courier and with that courier's other claims); (2) the ORDER row is locked next, so a
-- second claimant blocks here until the first transaction ends and then sees status <> 'available';
-- (3) the UPDATE re-checks status/courier; (4) the unique index orders_one_active_per_courier is
-- the final backstop.  Lock order is always courier row -> order row (no deadlock with approve/assign).
create or replace function public.claim_order(p_order uuid) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_uid uuid := (select auth.uid()); v_ok boolean; v_av boolean;
        v_st public.order_status; v_cur uuid;
begin
  if v_uid is null then raise exception 'not_approved_courier' using errcode = '42501'; end if;
  select (cp.approved and p.role = 'courier'), cp.available into v_ok, v_av
    from public.courier_profiles cp join public.profiles p on p.id = cp.user_id
   where cp.user_id = v_uid for update of cp;
  if not found or not v_ok then raise exception 'not_approved_courier' using errcode = '42501'; end if;
  if not v_av then raise exception 'courier_not_available' using errcode = 'P0001'; end if;
  if exists (select 1 from public.orders o
             where o.courier_id = v_uid and o.status in ('assigned', 'picked', 'transit')) then
    raise exception 'courier_has_active_order' using errcode = 'P0001';
  end if;

  select o.status, o.courier_id into v_st, v_cur from public.orders o where o.id = p_order for update;
  if not found or v_st <> 'available' or v_cur is not null then
    raise exception 'order_unavailable' using errcode = 'P0001';
  end if;

  update public.orders
     set status = 'assigned', courier_id = v_uid
   where id = p_order and status = 'available' and courier_id is null
  returning * into v_order;
  if not found then raise exception 'order_unavailable' using errcode = 'P0001'; end if;
  return v_order;
exception when unique_violation then
  raise exception 'courier_has_active_order' using errcode = 'P0001';
end;
$$;

create or replace function public.advance_order(p_order uuid, p_to public.order_status)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  if (select auth.uid()) is null or not app_private.is_approved_courier() then
    raise exception 'not_approved_courier' using errcode = '42501';
  end if;
  update public.orders set status = p_to
   where id = p_order and courier_id = (select auth.uid())
     and ((status = 'assigned' and p_to = 'picked')
       or (status = 'picked'   and p_to = 'transit')
       or (status = 'transit'  and p_to = 'delivered'))
  returning * into v_order;
  if not found then raise exception 'invalid_transition' using errcode = 'P0001'; end if;
  return v_order;
end;
$$;

-- The assigned courier or an admin reports a problem on a live order.
create or replace function public.report_exception(p_order uuid, p_note text)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  update public.orders o set status = 'exception', exception_note = left(p_note, 500)
   where o.id = p_order and o.status in ('assigned', 'picked', 'transit')
     and ((o.courier_id = (select auth.uid()) and app_private.is_approved_courier())
          or app_private.is_admin())
  returning * into v_order;
  if not found then raise exception 'invalid_transition' using errcode = 'P0001'; end if;
  return v_order;
end;
$$;

-- Merchant: only their own order while still available.  Admin: any live order.
create or replace function public.cancel_order(p_order uuid, p_reason text default null)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  update public.orders o set status = 'cancelled', cancel_reason = left(p_reason, 300)
   where o.id = p_order
     and ((app_private.owns_merchant(o.merchant_id) and o.status = 'available')
       or (app_private.is_admin() and o.status in ('available', 'assigned', 'picked', 'transit', 'exception')))
  returning * into v_order;
  if not found then raise exception 'cannot_cancel' using errcode = 'P0001'; end if;
  return v_order;
end;
$$;

-- ---------- RPC: admin -------------------------------------------------------
-- Assign / reassign: from available, assigned (reassignment) or exception.
create or replace function public.assign_order(p_order uuid, p_courier uuid)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  perform 1 from public.courier_profiles cp join public.profiles p on p.id = cp.user_id
   where cp.user_id = p_courier and cp.approved and p.role = 'courier' for share of cp;
  if not found then raise exception 'courier_not_approved' using errcode = 'P0001'; end if;
  update public.orders set status = 'assigned', courier_id = p_courier
   where id = p_order and status in ('available', 'assigned', 'exception')
  returning * into v_order;
  if not found then raise exception 'invalid_transition' using errcode = 'P0001'; end if;
  return v_order;
exception when unique_violation then
  raise exception 'courier_has_active_order' using errcode = 'P0001';
end;
$$;

-- Put an assigned or exception order back in the pool.
create or replace function public.release_order(p_order uuid)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.orders set status = 'available', courier_id = null
   where id = p_order and status in ('assigned', 'exception')
  returning * into v_order;
  if not found then raise exception 'invalid_transition' using errcode = 'P0001'; end if;
  return v_order;
end;
$$;

create or replace function public.set_priority_override(p_order uuid, p_level smallint)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.orders set priority_override = p_level where id = p_order returning * into v_order;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  return v_order;
end;
$$;

-- The courier fee is the only commercial field an admin edits, and only before pickup.
-- Admin sets the courier pay; only before pickup.  p_fee NULL removes it.  Logged (admin-only event).
create or replace function public.set_courier_fee(p_order uuid, p_fee numeric)
returns public.order_fees
language plpgsql security definer set search_path = '' as $$
declare v_row public.order_fees; v_old numeric;
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_fee is not null and (p_fee < 0 or p_fee > 99999.99) then
    raise exception 'invalid_fee' using errcode = 'P0001';
  end if;
  perform 1 from public.orders o where o.id = p_order and o.status in ('available', 'assigned') for update;
  if not found then raise exception 'invalid_transition' using errcode = 'P0001'; end if;
  select f.amount into v_old from public.order_fees f where f.order_id = p_order;
  if p_fee is null then
    delete from public.order_fees where order_id = p_order;
  else
    insert into public.order_fees (order_id, amount, updated_by)
    values (p_order, p_fee, (select auth.uid()))
    on conflict (order_id) do update
      set amount = excluded.amount, updated_by = excluded.updated_by, updated_at = now()
    returning * into v_row;
  end if;
  insert into public.order_events (order_id, actor_id, kind, details)
  values (p_order, (select auth.uid()), 'fee_changed', jsonb_build_object('from', v_old, 'to', p_fee));
  return v_row;
end;
$$;

-- Un-approving: the courier row is locked first (serialises with claim_order), assigned-but-not-
-- picked orders return to the pool, and it is refused while goods are with the courier.
create or replace function public.approve_courier(p_user uuid, p_approved boolean)
returns public.courier_profiles
language plpgsql security definer set search_path = '' as $$
declare v_row public.courier_profiles;
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  perform 1 from public.courier_profiles cp where cp.user_id = p_user for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if not p_approved then
    if exists (select 1 from public.orders o
               where o.courier_id = p_user and o.status in ('picked', 'transit')) then
      raise exception 'courier_has_active_orders' using errcode = 'P0001';
    end if;
    update public.orders set status = 'available', courier_id = null
     where courier_id = p_user and status = 'assigned';
  end if;
  update public.courier_profiles
     set approved = p_approved,
         approved_at = case when p_approved then now() end,
         approved_by = case when p_approved then (select auth.uid()) end,
         available = case when p_approved then available else false end
   where user_id = p_user returning * into v_row;
  return v_row;
end;
$$;

-- Admin-only full-detail reads (the table grants hide these columns from everyone).
create or replace function public.admin_order_events(p_order uuid)
returns setof public.order_events
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return query select e.* from public.order_events e where e.order_id = p_order order by e.created_at, e.id;
end;
$$;

-- Admin: full AI rows.  With p_only_pending the list excludes orders that are already closed
-- (delivered / cancelled), because those results can no longer be reviewed.
create or replace function public.admin_ai_results(p_order uuid default null, p_only_pending boolean default false)
returns setof public.order_ai_results
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  return query select r.* from public.order_ai_results r
   where (p_order is null or r.order_id = p_order)
     and (not p_only_pending
          or (r.review_status = 'pending'
              and exists (select 1 from public.orders o
                          where o.id = r.order_id and o.status not in ('delivered', 'cancelled'))))
   order by r.created_at desc limit 200;
end;
$$;

-- SERVER ONLY: the work queue for the AI worker (Edge Function).  Open orders that have no usable
-- classification yet.  The worker passes current_version back as p_expected_version.
create or replace function public.ai_next_jobs(p_limit int default 20)
returns table (order_id uuid, items text[], current_version int, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app_private.is_server() then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select o.id, o.items,
           coalesce((select max(r.version) from public.order_ai_results r where r.order_id = o.id), 0)::int,
           o.created_at
      from public.orders o
     where o.status in ('available', 'assigned', 'picked', 'transit', 'exception')
       and o.classification_status = 'unclassified'
     order by o.created_at
     limit least(greatest(coalesce(p_limit, 20), 1), 100);
end;
$$;

-- ---------- RPC: AI -----------------------------------------------------------
-- SERVER ONLY (Edge Function with the service_role key).  p_expected_version = highest version the
-- server saw when it started (0 if none); mismatch => STALE, rejected.  Input must equal the items.
create or replace function public.record_ai_result(
  p_order uuid, p_expected_version int, p_source text, p_model text,
  p_categories text[], p_confidence numeric, p_reason text,
  p_needs_verification boolean default false, p_input_items text[] default null
) returns public.order_ai_results
language plpgsql security definer set search_path = '' as $$
declare v_res public.order_ai_results; v_cur int; v_thr numeric; v_auto boolean;
        v_items text[]; v_status public.order_status;
begin
  if not app_private.is_server() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_source not in ('local_rules', 'server_model') then
    raise exception 'invalid_source' using errcode = 'P0001';
  end if;
  if p_categories is null or cardinality(p_categories) > 10 then
    raise exception 'invalid_categories' using errcode = 'P0001';
  end if;
  if p_confidence is not null and (p_confidence < 0 or p_confidence > 1) then
    raise exception 'invalid_confidence' using errcode = 'P0001';
  end if;
  select o.items, o.status into v_items, v_status
    from public.orders o where o.id = p_order for update;                 -- serialises writers
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_status in ('delivered', 'cancelled') then
    raise exception 'order_closed' using errcode = 'P0001';
  end if;
  if p_input_items is not null and p_input_items <> v_items then
    raise exception 'stale_input' using errcode = 'P0001';
  end if;
  select coalesce(max(r.version), 0) into v_cur from public.order_ai_results r where r.order_id = p_order;
  if p_expected_version is distinct from v_cur then
    raise exception 'stale_result' using errcode = 'P0001';
  end if;
  select s.auto_approve_threshold into v_thr from public.ai_settings s limit 1;
  v_auto := v_thr is not null and p_confidence is not null
            and p_confidence >= v_thr and not coalesce(p_needs_verification, false)
            and cardinality(p_categories) >= 1;

  insert into public.order_ai_results
    (order_id, version, source, model, input_items, suggested_categories, confidence, reason,
     needs_verification, review_status, final_categories)
  values
    (p_order, v_cur + 1, p_source, p_model, v_items, p_categories, p_confidence,
     left(p_reason, 500), coalesce(p_needs_verification, false),
     case when v_auto then 'auto_approved'::public.ai_review_status else 'pending' end,
     case when v_auto then p_categories end)
  returning * into v_res;
  return v_res;
end;
$$;

-- Admin reviews ONLY the newest result of an order, only while pending, only on an open order.
create or replace function public.review_ai_result(
  p_result uuid, p_approve boolean, p_final_categories text[] default null, p_note text default null
) returns public.order_ai_results
language plpgsql security definer set search_path = '' as $$
declare v_res public.order_ai_results; v_order uuid; v_status public.order_status; v_cats text[];
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select r.order_id into v_order from public.order_ai_results r where r.id = p_result;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  select o.status into v_status from public.orders o where o.id = v_order for update;   -- same lock as record_ai_result
  if v_status in ('delivered', 'cancelled') then
    raise exception 'order_closed' using errcode = 'P0001';
  end if;
  if p_approve then
    select coalesce(p_final_categories, r.suggested_categories) into v_cats
      from public.order_ai_results r where r.id = p_result;
    if v_cats is null or cardinality(v_cats) < 1 or cardinality(v_cats) > 10 then
      raise exception 'categories_required' using errcode = 'P0001';
    end if;
  end if;
  update public.order_ai_results r
     set review_status = case when p_approve then 'approved'::public.ai_review_status else 'rejected' end,
         final_categories = case when p_approve then v_cats end,
         reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = left(p_note, 500)
   where r.id = p_result and r.review_status = 'pending'
     and r.version = (select max(x.version) from public.order_ai_results x where x.order_id = r.order_id)
  returning * into v_res;
  if not found then raise exception 'not_pending_or_stale' using errcode = 'P0001'; end if;
  return v_res;
end;
$$;

-- Admin classifies by hand (recorded as an approved 'admin_manual' result) on an open order.
create or replace function public.classify_order_manually(p_order uuid, p_categories text[], p_reason text default null)
returns public.order_ai_results
language plpgsql security definer set search_path = '' as $$
declare v_res public.order_ai_results; v_ver int; v_items text[]; v_status public.order_status;
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_categories is null or cardinality(p_categories) < 1 or cardinality(p_categories) > 10 then
    raise exception 'categories_required' using errcode = 'P0001';
  end if;
  select o.items, o.status into v_items, v_status from public.orders o where o.id = p_order for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_status in ('delivered', 'cancelled') then
    raise exception 'order_closed' using errcode = 'P0001';
  end if;
  select coalesce(max(r.version), 0) + 1 into v_ver from public.order_ai_results r where r.order_id = p_order;
  insert into public.order_ai_results
    (order_id, version, source, input_items, suggested_categories, confidence, reason,
     review_status, final_categories, reviewed_by, reviewed_at)
  values (p_order, v_ver, 'admin_manual', v_items, p_categories, 1, left(p_reason, 500),
          'approved', p_categories, (select auth.uid()), now())
  returning * into v_res;
  return v_res;
end;
$$;

-- ---------- RPC: courier info / location -------------------------------------
-- A merchant sees the courier of THEIR order (name, phone, vehicle) only while it is in progress.
create or replace function public.get_order_courier(p_order uuid)
returns table (courier_id uuid, full_name text, name_ar text, name_en text, phone text, vehicle text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.full_name, p.name_ar, p.name_en, p.phone, cp.vehicle
  from public.orders o
  join public.profiles p on p.id = o.courier_id
  left join public.courier_profiles cp on cp.user_id = p.id
  where o.id = p_order
    and ( app_private.is_admin()
       or (app_private.owns_merchant(o.merchant_id) and o.status in ('assigned', 'picked', 'transit')) );
$$;

create or replace function public.set_location_consent(p_consent boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null or not exists (select 1 from public.courier_profiles where user_id = v_uid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.courier_profiles
     set location_consent_at = case when p_consent then now() end
   where user_id = v_uid;
  if not p_consent then   -- withdrawing consent erases stored positions
    delete from public.courier_locations_latest  where courier_id = v_uid;
    delete from public.courier_location_history where courier_id = v_uid;
  end if;
end;
$$;

-- Stores a GPS point only if: approved courier, consent given, and the courier has an active order
-- (the point is ALWAYS tied to that one order; the unique index guarantees there is at most one).
-- Rejected (nothing stored): timestamp older than 2 min / in the future / not newer than the last
-- point, accuracy worse than 500 m, (0,0), an impossible jump (> 83 m/s and > 300 m), calls closer
-- than 2 s apart.  Without an active order nothing is stored and the live row is deleted (returns false).
-- One writer per courier at a time (advisory lock), so the checks below cannot race.
create or replace function public.report_location(
  p_lat double precision, p_lng double precision,
  p_accuracy_m numeric default null, p_heading_deg numeric default null,
  p_speed_mps numeric default null, p_recorded_at timestamptz default null
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_order uuid; v_at timestamptz;
  v_prev public.courier_locations_latest;
  v_dist double precision; v_dt double precision;
begin
  if v_uid is null or not app_private.is_approved_courier() then
    raise exception 'not_approved_courier' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('saai_loc:' || v_uid::text, 0));

  if not exists (select 1 from public.courier_profiles cp
                 where cp.user_id = v_uid and cp.location_consent_at is not null) then
    raise exception 'location_consent_required' using errcode = 'P0001';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or (abs(p_lat) < 0.001 and abs(p_lng) < 0.001) then
    raise exception 'invalid_coordinates' using errcode = 'P0001';
  end if;
  if p_accuracy_m is not null and (p_accuracy_m < 0 or p_accuracy_m > 500) then
    raise exception 'low_accuracy' using errcode = 'P0001';
  end if;
  if (p_heading_deg is not null and p_heading_deg not between 0 and 360)
     or (p_speed_mps is not null and p_speed_mps not between 0 and 100) then
    raise exception 'invalid_motion_data' using errcode = 'P0001';
  end if;
  v_at := coalesce(p_recorded_at, now());
  if v_at < now() - interval '2 minutes' then raise exception 'stale_location' using errcode = 'P0001'; end if;
  if v_at > now() + interval '30 seconds' then raise exception 'invalid_timestamp' using errcode = 'P0001'; end if;

  select o.id into v_order from public.orders o
   where o.courier_id = v_uid and o.status in ('assigned', 'picked', 'transit') limit 1;
  if v_order is null then
    delete from public.courier_locations_latest where courier_id = v_uid;
    return false;
  end if;

  select * into v_prev from public.courier_locations_latest cl where cl.courier_id = v_uid;
  if found then
    if v_prev.updated_at > now() - interval '2 seconds' then
      raise exception 'too_frequent' using errcode = 'P0001';
    end if;
    if v_prev.order_id is not distinct from v_order then
      if v_at <= v_prev.recorded_at then raise exception 'stale_location' using errcode = 'P0001'; end if;
      v_dt   := greatest(extract(epoch from (v_at - v_prev.recorded_at)), 1);
      v_dist := 6371000 * 2 * asin(least(1, sqrt(
                  power(sin(radians(p_lat - v_prev.lat) / 2), 2)
                  + cos(radians(v_prev.lat)) * cos(radians(p_lat))
                    * power(sin(radians(p_lng - v_prev.lng) / 2), 2))));
      if v_dist > 300 and v_dist / v_dt > 83 then
        raise exception 'implausible_jump' using errcode = 'P0001';
      end if;
    end if;
  end if;

  insert into public.courier_locations_latest as l
    (courier_id, order_id, lat, lng, accuracy_m, heading_deg, speed_mps, recorded_at, updated_at)
  values (v_uid, v_order, p_lat, p_lng, p_accuracy_m, p_heading_deg, p_speed_mps, v_at, now())
  on conflict (courier_id) do update
    set order_id = excluded.order_id, lat = excluded.lat, lng = excluded.lng,
        accuracy_m = excluded.accuracy_m, heading_deg = excluded.heading_deg,
        speed_mps = excluded.speed_mps, recorded_at = excluded.recorded_at, updated_at = now()
    where l.recorded_at < excluded.recorded_at or l.order_id is distinct from excluded.order_id;

  if not exists (select 1 from public.courier_location_history h
                 where h.courier_id = v_uid and h.created_at > now() - interval '15 seconds') then
    insert into public.courier_location_history (courier_id, order_id, lat, lng, accuracy_m, recorded_at)
    values (v_uid, v_order, p_lat, p_lng, p_accuracy_m, v_at);
  end if;
  return true;
end;
$$;

-- The ONLY way to read a live position.  Authorised: the courier (own), the order's merchant
-- (picked/transit only), an admin (logged, visible to the courier).  The stored point must belong
-- to THIS order (order_id match) and be fresh (10 min).
create or replace function public.get_order_courier_location(p_order uuid)
returns table (lat double precision, lng double precision, accuracy_m numeric, recorded_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_ord public.orders;
  v_loc public.courier_locations_latest;
  v_admin boolean := app_private.is_admin();
  v_owner boolean;
  v_live boolean;
begin
  select * into v_ord from public.orders ord where ord.id = p_order;
  if not found or v_ord.courier_id is null then return; end if;
  v_owner := app_private.owns_merchant(v_ord.merchant_id);
  v_live  := v_ord.status in ('assigned', 'picked', 'transit');
  if not ( (v_admin and v_live)
        or (v_ord.courier_id = v_uid and v_live)
        or (v_owner and v_ord.status in ('picked', 'transit')) ) then
    return;
  end if;
  select * into v_loc from public.courier_locations_latest cl
   where cl.courier_id = v_ord.courier_id and cl.order_id = p_order
     and cl.recorded_at > now() - interval '10 minutes';
  if not found then return; end if;

  if v_admin and not v_owner and v_ord.courier_id is distinct from v_uid
     and not exists (select 1 from public.location_access_log a
                     where a.viewer_id = v_uid and a.order_id = p_order and a.kind = 'live'
                       and a.created_at > now() - interval '5 minutes') then
    insert into public.location_access_log (viewer_id, courier_id, order_id, kind)
    values (v_uid, v_ord.courier_id, p_order, 'live');
  end if;
  return query select v_loc.lat, v_loc.lng, v_loc.accuracy_m, v_loc.recorded_at;
end;
$$;

-- Admin-only history for one order (logged).
create or replace function public.admin_location_history(p_order uuid, p_limit int default 200)
returns setof public.courier_location_history
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_courier uuid;
begin
  if not app_private.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select o.courier_id into v_courier from public.orders o where o.id = p_order;
  if v_courier is not null then
    insert into public.location_access_log (viewer_id, courier_id, order_id, kind)
    values (v_uid, v_courier, p_order, 'history');
  end if;
  return query select h.* from public.courier_location_history h
   where h.order_id = p_order order by h.recorded_at desc limit least(greatest(p_limit, 1), 1000);
end;
$$;

-- SERVER/CRON ONLY (guarded here as well as by GRANT).  Cleans: old history (default 30 days),
-- CURRENT positions that are stale (> 1 h without update) or no longer tied to an active order,
-- and old access-log rows (default 365 days).  Minimums stop an accidental "delete everything".
-- Schedule it (pg_cron is NOT enabled by this file), e.g. every 15 minutes:
--   select cron.schedule('saai-gps-purge', '*/15 * * * *', $cron$select public.purge_courier_locations()$cron$);
create or replace function public.purge_courier_locations(
  p_history_keep interval default interval '30 days',
  p_latest_ttl   interval default interval '1 hour',
  p_log_keep     interval default interval '365 days'
) returns table (history_deleted bigint, latest_deleted bigint, log_deleted bigint)
language plpgsql security definer set search_path = '' as $$
declare v_h bigint; v_l bigint; v_a bigint;
begin
  if not app_private.is_server() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_history_keep is null or p_history_keep < interval '1 day'
     or p_latest_ttl is null or p_latest_ttl < interval '5 minutes'
     or p_log_keep is null or p_log_keep < interval '30 days' then
    raise exception 'retention_too_short' using errcode = 'P0001';
  end if;
  with d as (delete from public.courier_location_history h
              where h.recorded_at < now() - p_history_keep returning 1)
  select count(*) into v_h from d;
  with d as (delete from public.courier_locations_latest cl
              where cl.updated_at < now() - p_latest_ttl
                 or not exists (select 1 from public.orders o
                                where o.id = cl.order_id and o.courier_id = cl.courier_id
                                  and o.status in ('assigned', 'picked', 'transit'))
              returning 1)
  select count(*) into v_l from d;
  with d as (delete from public.location_access_log a
              where a.created_at < now() - p_log_keep returning 1)
  select count(*) into v_a from d;
  return query select v_h, v_l, v_a;
end;
$$;

-- ---------- Row Level Security ----------------------------------------------
alter table public.countries                enable row level security;
alter table public.cities                   enable row level security;
alter table public.priority_rules           enable row level security;
alter table public.ai_settings              enable row level security;
alter table public.profiles                 enable row level security;
alter table public.merchants                enable row level security;
alter table public.merchant_contacts        enable row level security;
alter table public.courier_profiles         enable row level security;
alter table public.orders                   enable row level security;
alter table public.order_recipients         enable row level security;
alter table public.order_fees               enable row level security;
alter table public.order_events             enable row level security;
alter table public.order_ai_results         enable row level security;
alter table public.notifications            enable row level security;
alter table public.courier_locations_latest enable row level security;
alter table public.courier_location_history enable row level security;
alter table public.location_access_log      enable row level security;

do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'countries' and policyname = 'countries_read') then
    create policy countries_read on public.countries for select to authenticated using (true);
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'cities' and policyname = 'cities_read') then
    create policy cities_read    on public.cities    for select to authenticated using (true);
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'countries' and policyname = 'countries_admin_write') then
    create policy countries_admin_write on public.countries for all to authenticated
  using (app_private.is_admin()) with check (app_private.is_admin());
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'cities' and policyname = 'cities_admin_write') then
    create policy cities_admin_write on public.cities for all to authenticated
  using (app_private.is_admin()) with check (app_private.is_admin());
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'priority_rules' and policyname = 'rules_read') then
    create policy rules_read on public.priority_rules for select to authenticated using (true);
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'priority_rules' and policyname = 'rules_admin_update') then
    create policy rules_admin_update on public.priority_rules for update to authenticated
  using (app_private.is_admin()) with check (app_private.is_admin());
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ai_settings' and policyname = 'ai_settings_admin') then
    create policy ai_settings_admin on public.ai_settings for all to authenticated
  using (app_private.is_admin()) with check (app_private.is_admin());
  end if;
end $p$;

-- People: own row or admin.  Couriers/merchants see each other only through narrow functions.
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'profiles' and policyname = 'profiles_select') then
    create policy profiles_select on public.profiles for select to authenticated using (
  id = (select auth.uid()) or app_private.is_admin());
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'profiles' and policyname = 'profiles_update_own') then
    create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
  end if;
end $p$;

do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'merchants' and policyname = 'merchants_select') then
    create policy merchants_select on public.merchants for select to authenticated using (
  owner_id = (select auth.uid()) or app_private.is_admin());
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'merchants' and policyname = 'merchants_update_own') then
    create policy merchants_update_own on public.merchants for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
  end if;
end $p$;

do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'merchant_contacts' and policyname = 'merchant_contacts_select') then
    create policy merchant_contacts_select on public.merchant_contacts for select to authenticated using (
  app_private.owns_merchant(merchant_id) or app_private.is_admin()
  or app_private.courier_works_for_merchant(merchant_id));
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'merchant_contacts' and policyname = 'merchant_contacts_insert') then
    create policy merchant_contacts_insert on public.merchant_contacts for insert to authenticated
  with check (app_private.owns_merchant(merchant_id));
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'merchant_contacts' and policyname = 'merchant_contacts_update') then
    create policy merchant_contacts_update on public.merchant_contacts for update to authenticated
  using (app_private.owns_merchant(merchant_id)) with check (app_private.owns_merchant(merchant_id));
  end if;
end $p$;

do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'courier_profiles' and policyname = 'couriers_select') then
    create policy couriers_select on public.courier_profiles for select to authenticated using (
  user_id = (select auth.uid()) or app_private.is_admin());
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'courier_profiles' and policyname = 'couriers_update_own') then
    create policy couriers_update_own on public.courier_profiles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
  end if;
end $p$;

-- Orders: merchant = own merchant's orders; approved courier = available + own; admin = all.
-- No INSERT policy and no UPDATE policy: all writes go through the RPCs above.
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'orders' and policyname = 'orders_select') then
    create policy orders_select on public.orders for select to authenticated using (
  app_private.is_admin()
  or app_private.owns_merchant(merchant_id)
  or (app_private.is_approved_courier() and (status = 'available' or courier_id = (select auth.uid()))));
  end if;
end $p$;

-- Courier pay: admin, or an approved courier who can already see the order (available / own).
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'order_fees' and policyname = 'fees_select') then
    create policy fees_select on public.order_fees for select to authenticated using (
  app_private.is_admin()
  or (app_private.is_approved_courier()
      and exists (select 1 from public.orders o where o.id = order_fees.order_id)));
  end if;
end $p$;

do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'order_recipients' and policyname = 'recipients_select') then
    create policy recipients_select on public.order_recipients for select to authenticated using (
  app_private.is_admin()
  or exists (select 1 from public.orders o
             where o.id = order_recipients.order_id
               and (app_private.owns_merchant(o.merchant_id)
                    or (o.courier_id = (select auth.uid()) and o.status in ('assigned', 'picked', 'transit')))));
  end if;
end $p$;

-- EVENTS: admin -> all rows; others -> only orders they own / are assigned to, basic kinds only.
-- Column grants below hide actor_id and details from everyone (admins use admin_order_events()).
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'order_events' and policyname = 'events_select') then
    create policy events_select on public.order_events for select to authenticated using (
  app_private.is_admin()
  or (kind in ('created', 'status_changed') and app_private.can_view_order_events(order_id)));
  end if;
end $p$;

-- AI results: admin or the owning merchant (limited columns by grant).  No write policy.
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'order_ai_results' and policyname = 'ai_results_select') then
    create policy ai_results_select on public.order_ai_results for select to authenticated using (
  app_private.is_admin()
  or exists (select 1 from public.orders o
             where o.id = order_ai_results.order_id and app_private.owns_merchant(o.merchant_id)));
  end if;
end $p$;

do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'notifications' and policyname = 'notifications_select') then
    create policy notifications_select on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'notifications' and policyname = 'notifications_update_own') then
    create policy notifications_update_own on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
  end if;
end $p$;

-- GPS tables: ONLY the courier's own rows. Admins/merchants use the logged functions.
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'courier_locations_latest' and policyname = 'loc_latest_own') then
    create policy loc_latest_own  on public.courier_locations_latest for select to authenticated
  using (courier_id = (select auth.uid()));
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'courier_location_history' and policyname = 'loc_history_own') then
    create policy loc_history_own on public.courier_location_history for select to authenticated
  using (courier_id = (select auth.uid()));
  end if;
end $p$;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'location_access_log' and policyname = 'loc_log_select') then
    create policy loc_log_select on public.location_access_log for select to authenticated
  using (courier_id = (select auth.uid()) or app_private.is_admin());
  end if;
end $p$;

-- ---------- Privileges -------------------------------------------------------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public      from public, anon, authenticated;
revoke all on all functions in schema app_private from public, anon, authenticated;

grant select on
  public.countries, public.cities, public.priority_rules, public.ai_settings,
  public.profiles, public.merchants, public.merchant_contacts, public.courier_profiles,
  public.orders, public.order_fees, public.order_recipients, public.notifications,
  public.courier_locations_latest, public.courier_location_history,
  public.orders_prioritized, public.order_ai_current
  to authenticated;

-- Column-limited reads
grant select (id, order_id, kind, from_status, to_status, created_at)
  on public.order_events to authenticated;                       -- no actor_id, no details
grant select (id, order_id, version, source, suggested_categories, confidence, reason,
              needs_verification, review_status, final_categories, reviewed_at, created_at)
  on public.order_ai_results to authenticated;                   -- no model, input_items, reviewer, note
grant select (id, viewer_id, courier_id, order_id, kind, created_at)
  on public.location_access_log to authenticated;

grant insert, update on public.countries, public.cities to authenticated;          -- admin only by RLS
grant update (auto_approve_threshold) on public.ai_settings to authenticated;       -- admin only by RLS
grant update (critical_hours, high_hours, normal_hours, aging_hours, handling_raises,
              fragile_min_level, temperature_min_level, health_min_level)
  on public.priority_rules to authenticated;                                        -- admin only by RLS
grant update (full_name, name_ar, name_en, phone, city_id, lang, theme, calendar)
  on public.profiles to authenticated;
grant update (name, city_id)              on public.merchants        to authenticated;
grant insert (merchant_id, phone), update (phone) on public.merchant_contacts to authenticated;
grant update (vehicle, available)         on public.courier_profiles to authenticated;
grant update (read_at)                    on public.notifications    to authenticated;
-- orders: NO insert/update grant for app users at all.

-- Private helpers: needed by RLS policies, views and constraints evaluated as the caller.
grant execute on function
  app_private.is_admin(), app_private.is_approved_courier(), app_private.owns_merchant(uuid),
  app_private.courier_works_for_merchant(uuid), app_private.can_view_order_events(uuid),
  app_private.text_arr_ok(text[], int), app_private.priority_details(public.orders)
  to authenticated;
-- normalize_phone / is_server are only called from SECURITY DEFINER functions; no grant.

-- Public RPC surface for signed-in users
grant execute on function
  public.create_order(uuid, text, text, text[], uuid, text, uuid, text,
      double precision, double precision, double precision, double precision,
      timestamptz, boolean, boolean, boolean),
  public.claim_order(uuid), public.advance_order(uuid, public.order_status),
  public.report_exception(uuid, text), public.cancel_order(uuid, text),
  public.assign_order(uuid, uuid), public.release_order(uuid),
  public.set_priority_override(uuid, smallint), public.set_courier_fee(uuid, numeric),
  public.approve_courier(uuid, boolean),
  public.review_ai_result(uuid, boolean, text[], text),
  public.classify_order_manually(uuid, text[], text),
  public.admin_order_events(uuid), public.admin_ai_results(uuid, boolean),
  public.admin_location_history(uuid, int),
  public.get_order_courier(uuid), public.get_order_courier_location(uuid),
  public.set_location_consent(boolean),
  public.report_location(double precision, double precision, numeric, numeric, numeric, timestamptz)
  to authenticated;

-- Server-only
grant execute on function
  public.record_ai_result(uuid, int, text, text, text[], numeric, text, boolean, text[]),
  public.ai_next_jobs(int),
  public.purge_courier_locations(interval, interval, interval)
  to service_role;
grant execute on function app_private.normalize_phone(text, text), app_private.is_server()
  to service_role;

-- New objects created by later migrations must not be exposed by default.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- ---------- After running (manual, NOT part of this migration) --------------
-- 1) First admin: sign up, then:  update public.profiles set role = 'admin' where id = '<uuid>';
-- 2) Approve test couriers as that admin: select public.approve_courier('<uuid>', true);
-- 3) AI flow: Edge Function (service_role key, server only) reads the order, calls
--      record_ai_result(order, <highest version it saw, 0 if none>, ...);
--    an admin then calls review_ai_result(...).
-- 4) Schedule select public.purge_courier_locations(interval '30 days'); (pg_cron NOT enabled here)
-- 5) Do NOT add orders / GPS tables to supabase_realtime without a separate review.
-- 6) Verify with two accounts per role (see the report, section "Tests to run").

-- ---------- GPS cleanup schedule (pg_cron) -----------------------------------------------------
-- Tries to enable pg_cron and schedule purge_courier_locations() every 15 minutes.  If pg_cron is not
-- available the file still succeeds and prints a NOTICE: enable it in Dashboard > Database > Extensions,
-- then re-run this block (or the whole file).  The job runs as the owner, which app_private.is_server()
-- accepts.
do $cron$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule('saai-gps-purge', '*/15 * * * *', $job$select public.purge_courier_locations()$job$);
exception when others then
  raise notice 'GPS purge NOT scheduled (pg_cron unavailable): %. Enable pg_cron and re-run this block.', sqlerrm;
end
$cron$;

-- ---------- External setup for the AI worker (not SQL) ----------------------------------------------
-- An Edge Function (or any trusted server) using the service_role key must:
--   1. call  select * from public.ai_next_jobs(20)              -> order_id, items, current_version
--   2. classify the items
--   3. call  public.record_ai_result(order_id, current_version, 'server_model', '<model>',
--                                    categories, confidence, reason, needs_verification, items)
-- Trigger it from a Database Webhook on INSERT into public.orders, and/or on a schedule, so orders whose
-- first attempt failed are retried.  stale_result / stale_input / order_closed errors mean "skip this job".
-- An admin then approves or rejects with public.review_ai_result(...).  Never put the service_role key
-- in the browser.

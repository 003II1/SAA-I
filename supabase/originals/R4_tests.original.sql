-- =============================================================================
-- 0001_saai_core_tests_r4.sql  --  behavioural tests for 0001_saai_core_final_r4.sql
-- NOT RUN BY THE AUTHOR.  This harness itself is untested: a failing line may be a
-- bug in the test, not in the schema.  Read each FAIL before drawing conclusions.
--
-- HOW TO USE (on a TEST Supabase project, never on production):
--   1. Run 0001_saai_core_final_r4.sql in the SQL Editor (the file is re-runnable).
--   2. Paste and run THIS file.  It creates fake users inside one transaction, runs the
--      tests while impersonating each role (SET LOCAL ROLE + JWT claims), and ends by
--      raising an exception whose message is the report.  The exception ROLLS BACK
--      everything (users, orders, locations), so nothing is left behind.
--   3. The report is shown as the error text: "PASS=n FAIL=m" then one line per test.
--
-- NOT covered (a single transaction cannot do it): real concurrency between two
-- sessions.  The concurrency guarantees (unique index, row locks, advisory lock) must be
-- tested with two parallel connections.
-- =============================================================================
do $saai_test$
declare
  v_i int; v_max int; t record; kv record;
  v_sql text; v_tx text; v_out text; v_ok boolean; v_msg text; v_uid text; v_pass boolean;
  v_np int := 0; v_nf int := 0; v_rep text := '';
begin
  if to_regclass('public.orders') is null
     or to_regprocedure('app_private.is_admin()') is null
     or to_regprocedure('public.claim_order(uuid)') is null
     or to_regprocedure('public.ai_next_jobs(integer)') is null then
    raise exception 'Run 0001_saai_core_final_r4.sql first (schema or r4 functions are missing)';
  end if;

  create temp table u (k text primary key, v text);
  create temp table tt (n int generated always as identity, who text, kind text, sq text, ex text, tx text, sv text);

  insert into u select x, gen_random_uuid()::text from unnest(array['A','M1','M2','C1','C2','C3','C4','X']) x;
  insert into auth.users (id, aud, role, email, raw_user_meta_data)
  select v::uuid, 'authenticated', 'authenticated', lower(k) || '@saai-test.invalid',
         case when k like 'C%' then '{"role":"courier","full_name":"Courier"}'::jsonb
              when k = 'X' then '{"role":"admin"}'::jsonb
              else '{"store_name":"Store"}'::jsonb end
  from u;
  update public.profiles set role = 'admin' where id = (select v::uuid from u where k = 'A');
  insert into u select 'MR1', id::text from public.merchants where owner_id = (select v::uuid from u where k = 'M1');
  insert into u select 'MR2', id::text from public.merchants where owner_id = (select v::uuid from u where k = 'M2');
  insert into u select upper(left(slug, 3)), id::text from public.cities where slug in ('riyadh', 'jeddah', 'khobar');

  insert into tt (who, kind, sq, ex, tx, sv) values
  -- ---- sign-up and roles
  ('pg','s',$q$select count(*)::text from public.profiles where role='admin'$q$,'eq','1',null),
  ('pg','s',$q$select role::text from public.profiles where id='{X}'$q$,'eq','merchant',null),
  ('pg','s',$q$select (select count(*) from public.merchants)::text||'/'||(select count(*) from public.courier_profiles)::text$q$,'eq','4/4',null),
  ('M1','x',$q$update public.profiles set role='admin' where id='{M1}'$q$,'err','permission denied',null),
  ('C1','x',$q$update public.courier_profiles set approved=true where user_id='{C1}'$q$,'err','permission denied',null),
  -- ---- approvals / availability
  ('A','s',$q$select (public.approve_courier('{C1}',true)).approved::text$q$,'eq','true',null),
  ('A','s',$q$select (public.approve_courier('{C2}',true)).approved::text$q$,'eq','true',null),
  ('A','s',$q$select (public.approve_courier('{C4}',true)).approved::text$q$,'eq','true',null),
  ('C3','x',$q$update public.courier_profiles set available=true where user_id='{C3}'$q$,'err','courier_available_requires_approval',null),
  ('C1','x',$q$update public.courier_profiles set available=true where user_id='{C1}'$q$,'ok',null,null),
  ('C2','x',$q$update public.courier_profiles set available=true where user_id='{C2}'$q$,'ok',null,null),
  ('C4','x',$q$update public.courier_profiles set available=true where user_id='{C4}'$q$,'ok',null,null),
  -- ---- order creation
  ('M1','s',$q$select (public.create_order('{MR1}','Ali','0551234567',array['serum'],'{RIY}','Olaya','{JED}','Hittin')).id::text$q$,'ok',null,'O1'),
  ('M1','s',$q$select (public.create_order('{MR1}','Sara','+966501234567',array['insulin pen'],'{RIY}','Malqa','{RIY}','Yasmin',p_deadline=>now()+interval '1 hour',p_fragile=>true,p_temperature=>true)).id::text$q$,'ok',null,'O2'),
  ('M1','s',$q$select (public.create_order('{MR1}','Omar','0551112222',array['vaccine'],'{RIY}','Nakheel','{RIY}','Rawdah',p_deadline=>now()+interval '72 hours',p_temperature=>true)).id::text$q$,'ok',null,'O3'),
  ('M2','s',$q$select (public.create_order('{MR2}','Nora','0553334444',array['perfume'],'{RIY}','Olaya','{RIY}','Malaz')).id::text$q$,'ok',null,'O4'),
  ('M1','s',$q$select (public.create_order('{MR1}','Lina','0555556666',array['sunscreen'],'{RIY}','Hittin','{RIY}','Olaya')).id::text$q$,'ok',null,'O5'),
  ('M2','x',$q$select public.create_order('{MR1}','A','0551234567',array['x'],'{RIY}','a','{RIY}','b')$q$,'err','forbidden',null),
  ('M1','x',$q$select public.create_order('{MR1}','A','123',array['x'],'{RIY}','a','{RIY}','b')$q$,'err','invalid_phone',null),
  ('M1','x',$q$select public.create_order('{MR1}','A','0551234567',array['x'],'{RIY}','a','{RIY}','b',p_deadline=>now()-interval '1 day')$q$,'err','deadline_in_past',null),
  ('M1','x',$q$select public.create_order('{MR1}','A','0551234567',array['x'],'{RIY}','a','{RIY}','b',p_deadline=>now()+interval '200 days')$q$,'err','deadline_too_far',null),
  ('C1','x',$q$select public.create_order('{MR1}','A','0551234567',array['x'],'{RIY}','a','{RIY}','b')$q$,'err','forbidden',null),
  ('M1','x',$q$select public.create_order('{MR1}','A','0551234567',array['x'],'{RIY}','a','{RIY}','b',p_pickup_lat=>10,p_pickup_lng=>10)$q$,'err','pickup_outside_country',null),
  ('M1','x',$q$insert into public.orders (merchant_id,merchant_name,created_by,items,pickup_city_id,pickup_district,dropoff_city_id,dropoff_district) values ('{MR1}','m','{M1}',array['x'],'{RIY}','a','{RIY}','b')$q$,'err','permission denied',null),
  ('M1','x',$q$update public.orders set status='delivered' where id='{O1}'$q$,'err','permission denied',null),
  ('anon','x',$q$select count(*) from public.orders$q$,'err','permission denied',null),
  -- ---- visibility
  ('M1','s',$q$select count(*)::text from public.orders$q$,'eq','4',null),
  ('M2','s',$q$select count(*)::text from public.orders$q$,'eq','1',null),
  ('C1','s',$q$select count(*)::text from public.orders$q$,'eq','5',null),
  ('C3','s',$q$select count(*)::text from public.orders$q$,'eq','0',null),
  ('M2','s',$q$select count(*)::text from public.order_recipients where order_id='{O1}'$q$,'eq','0',null),
  ('M1','s',$q$select count(*)::text from public.order_recipients where order_id='{O1}'$q$,'eq','1',null),
  ('C1','s',$q$select count(*)::text from public.order_recipients where order_id='{O1}'$q$,'eq','0',null),
  -- ---- courier fee is hidden from merchants
  ('A','s',$q$select (public.set_courier_fee('{O1}',25.5)).amount::text$q$,'eq','25.50',null),
  ('M1','s',$q$select coalesce(courier_fee::text,'<null>') from public.orders_prioritized where id='{O1}'$q$,'eq','<null>',null),
  ('C1','s',$q$select coalesce(courier_fee::text,'<null>') from public.orders_prioritized where id='{O1}'$q$,'eq','25.50',null),
  ('M1','s',$q$select count(*)::text from public.order_fees$q$,'eq','0',null),
  ('M1','x',$q$select public.set_courier_fee('{O1}',5)$q$,'err','forbidden',null),
  ('A','x',$q$select public.set_courier_fee('{O1}',-1)$q$,'err','invalid_fee',null),
  -- ---- priority and reasons
  ('C1','s',$q$select priority::text from public.orders_prioritized where id='{O1}'$q$,'eq','0',null),
  ('C1','s',$q$select priority::text from public.orders_prioritized where id='{O2}'$q$,'eq','3',null),
  ('C1','s',$q$select (priority_reasons::text like '%deadline_critical%' and priority_reasons::text like '%handling_fragile%')::text from public.orders_prioritized where id='{O2}'$q$,'eq','true',null),
  ('C1','s',$q$select priority::text from public.orders_prioritized where id='{O3}'$q$,'eq','2',null),
  ('pg','s',$q$with i as (insert into public.orders (merchant_id,merchant_name,created_by,items,pickup_city_id,pickup_district,dropoff_city_id,dropoff_district,created_at) values ('{MR1}','m','{M1}',array['x'],'{RIY}','a','{RIY}','b',now()-interval '50 hours') returning id) select id::text from i$q$,'ok',null,'O6'),
  ('pg','s',$q$select priority::text||'/'||(priority_reasons::text like '%aging%')::text from public.orders_prioritized where id='{O6}'$q$,'eq','2/true',null),
  ('A','x',$q$select public.set_priority_override('{O5}',3::smallint)$q$,'ok',null,null),
  ('pg','s',$q$select priority::text from public.orders_prioritized where id='{O5}'$q$,'eq','3',null),
  ('A','x',$q$select public.set_priority_override('{O5}',null::smallint)$q$,'ok',null,null),
  -- ---- events: only own orders, no actor/details columns
  ('M2','s',$q$select count(*)::text from public.order_events where order_id='{O1}'$q$,'eq','0',null),
  ('C2','s',$q$select count(*)::text from public.order_events where order_id='{O1}'$q$,'eq','0',null),
  ('M1','s',$q$select count(*)::text from public.order_events where order_id='{O1}'$q$,'eq','1',null),
  ('M1','x',$q$select actor_id from public.order_events limit 1$q$,'err','permission denied',null),
  ('M1','x',$q$select * from public.order_events$q$,'err','permission denied',null),
  ('A','s',$q$select count(*)::text from public.admin_order_events('{O1}')$q$,'eq','2',null),
  -- ---- claiming
  ('C1','s',$q$select (public.claim_order('{O1}')).status::text$q$,'eq','assigned',null),
  ('C2','x',$q$select public.claim_order('{O1}')$q$,'err','order_unavailable',null),
  ('C1','x',$q$select public.claim_order('{O2}')$q$,'err','courier_has_active_order',null),
  ('C3','x',$q$select public.claim_order('{O3}')$q$,'err','not_approved_courier',null),
  ('pg','x',$q$update public.courier_profiles set available=false where user_id='{C2}'$q$,'ok',null,null),
  ('C2','x',$q$select public.claim_order('{O3}')$q$,'err','courier_not_available',null),
  ('pg','x',$q$update public.courier_profiles set available=true where user_id='{C2}'$q$,'ok',null,null),
  ('pg','x',$q$update public.orders set status='assigned', courier_id='{C1}' where id='{O3}'$q$,'err','orders_one_active_per_courier',null),
  ('C1','s',$q$select count(*)::text from public.order_recipients where order_id='{O1}'$q$,'eq','1',null),
  ('C2','s',$q$select count(*)::text from public.order_recipients where order_id='{O1}'$q$,'eq','0',null),
  ('M1','x',$q$insert into public.merchant_contacts (merchant_id, phone) values ('{MR1}','+966551111111')$q$,'ok',null,null),
  ('C1','s',$q$select count(*)::text from public.merchant_contacts$q$,'eq','1',null),
  ('C2','s',$q$select count(*)::text from public.merchant_contacts$q$,'eq','0',null),
  ('M2','s',$q$select count(*)::text from public.merchant_contacts$q$,'eq','0',null),
  ('C1','x',$q$select public.advance_order('{O1}','transit')$q$,'err','invalid_transition',null),
  ('C2','x',$q$select public.advance_order('{O1}','picked')$q$,'err','invalid_transition',null),
  -- ---- GPS
  ('C1','x',$q$select public.report_location(24.7136::float8,46.6753::float8)$q$,'err','location_consent_required',null),
  ('C1','x',$q$select public.set_location_consent(true)$q$,'ok',null,null),
  ('C1','s',$q$select public.report_location(24.7136::float8,46.6753::float8)::text$q$,'eq','true',null),
  ('C1','x',$q$select public.report_location(24.7137::float8,46.6754::float8)$q$,'err','too_frequent',null),
  ('pg','x',$q$update public.courier_locations_latest set updated_at=now()-interval '10 seconds', recorded_at=now()-interval '10 seconds' where courier_id='{C1}'$q$,'ok',null,null),
  ('C1','x',$q$select public.report_location(25.7136::float8,46.6753::float8)$q$,'err','implausible_jump',null),
  ('C1','x',$q$select public.report_location(24.7137::float8,46.6754::float8,null::numeric,null::numeric,null::numeric,now()-interval '5 minutes')$q$,'err','stale_location',null),
  ('C1','x',$q$select public.report_location(24.7137::float8,46.6754::float8,null::numeric,null::numeric,null::numeric,now()+interval '2 minutes')$q$,'err','invalid_timestamp',null),
  ('C1','x',$q$select public.report_location(24.7137::float8,46.6754::float8,800::numeric)$q$,'err','low_accuracy',null),
  ('C1','x',$q$select public.report_location(0::float8,0::float8)$q$,'err','invalid_coordinates',null),
  ('C1','s',$q$select public.report_location(24.7142::float8,46.6758::float8)::text$q$,'eq','true',null),
  ('pg','s',$q$select count(*)::text from public.courier_location_history where courier_id='{C1}'$q$,'eq','1',null),
  ('pg','s',$q$select (order_id='{O1}')::text from public.courier_locations_latest where courier_id='{C1}'$q$,'eq','true',null),
  ('M1','s',$q$select count(*)::text from public.get_order_courier_location('{O1}')$q$,'eq','0',null),
  ('C1','s',$q$select count(*)::text from public.get_order_courier_location('{O1}')$q$,'eq','1',null),
  ('A','s',$q$select count(*)::text from public.get_order_courier_location('{O1}')$q$,'eq','1',null),
  ('C2','s',$q$select count(*)::text from public.get_order_courier_location('{O1}')$q$,'eq','0',null),
  ('M2','s',$q$select count(*)::text from public.get_order_courier_location('{O1}')$q$,'eq','0',null),
  ('pg','s',$q$select count(*)::text from public.location_access_log where courier_id='{C1}'$q$,'eq','1',null),
  ('C1','s',$q$select count(*)::text from public.location_access_log$q$,'eq','1',null),
  ('M1','s',$q$select count(*)::text from public.location_access_log$q$,'eq','0',null),
  ('M1','s',$q$select count(*)::text from public.courier_locations_latest$q$,'eq','0',null),
  ('A','s',$q$select count(*)::text from public.courier_locations_latest$q$,'eq','0',null),
  ('C1','s',$q$select count(*)::text from public.courier_locations_latest$q$,'eq','1',null),
  ('A','s',$q$select count(*)::text from public.courier_location_history$q$,'eq','0',null),
  ('C2','s',$q$select count(*)::text from public.courier_locations_latest$q$,'eq','0',null),
  -- ---- state machine
  ('C1','s',$q$select (public.advance_order('{O1}','picked')).status::text$q$,'eq','picked',null),
  ('M1','s',$q$select count(*)::text from public.get_order_courier_location('{O1}')$q$,'eq','1',null),
  ('M2','s',$q$select count(*)::text from public.get_order_courier_location('{O1}')$q$,'eq','0',null),
  ('C1','s',$q$select (public.advance_order('{O1}','transit')).status::text$q$,'eq','transit',null),
  ('pg','x',$q$update public.orders set status='available', courier_id=null where id='{O1}'$q$,'err','invalid_status_transition',null),
  ('pg','x',$q$update public.orders set claimed_at=now() where id='{O1}'$q$,'err','timestamps_are_system_managed',null),
  ('M1','x',$q$select public.cancel_order('{O1}')$q$,'err','cannot_cancel',null),
  ('M1','s',$q$select (public.cancel_order('{O3}','changed mind')).status::text$q$,'eq','cancelled',null),
  ('M1','x',$q$select public.cancel_order('{O3}')$q$,'err','cannot_cancel',null),
  ('pg','x',$q$update public.orders set status='picked' where id='{O3}'$q$,'err','invalid_status_transition',null),
  ('C1','s',$q$select (public.advance_order('{O1}','delivered')).status::text$q$,'eq','delivered',null),
  ('pg','s',$q$select count(*)::text from public.courier_locations_latest where courier_id='{C1}'$q$,'eq','0',null),
  ('C1','s',$q$select public.report_location(24.7::float8,46.6::float8)::text$q$,'eq','false',null),
  ('C1','x',$q$select public.set_location_consent(false)$q$,'ok',null,null),
  ('pg','s',$q$select count(*)::text from public.courier_location_history where courier_id='{C1}'$q$,'eq','0',null),
  ('C2','x',$q$select public.set_location_consent(true)$q$,'ok',null,null),
  ('C2','s',$q$select public.report_location(24.7::float8,46.6::float8)::text$q$,'eq','false',null),
  -- ---- exception / reassignment / release
  ('C2','s',$q$select (public.claim_order('{O2}')).status::text$q$,'eq','assigned',null),
  ('A','s',$q$select (public.report_exception('{O2}','damaged box')).status::text$q$,'eq','exception',null),
  ('A','s',$q$select (public.assign_order('{O2}','{C4}')).courier_id::text$q$,'eq','{C4}',null),
  ('A','x',$q$select public.assign_order('{O2}','{C3}')$q$,'err','courier_not_approved',null),
  ('A','x',$q$select public.assign_order('{O4}','{C4}')$q$,'err','courier_has_active_order',null),
  ('pg','s',$q$select count(*)::text from public.notifications where user_id='{C2}' and kind='order_unassigned'$q$,'eq','1',null),
  ('A','s',$q$select (public.release_order('{O2}')).status::text$q$,'eq','available',null),
  ('pg','s',$q$select count(*)::text from public.notifications where user_id='{C4}' and kind='order_unassigned'$q$,'eq','1',null),
  -- ---- un-approving a courier
  ('C4','s',$q$select (public.claim_order('{O4}')).status::text$q$,'eq','assigned',null),
  ('C4','s',$q$select (public.advance_order('{O4}','picked')).status::text$q$,'eq','picked',null),
  ('A','x',$q$select public.approve_courier('{C4}',false)$q$,'err','courier_has_active_orders',null),
  ('C2','s',$q$select (public.claim_order('{O2}')).status::text$q$,'eq','assigned',null),
  ('A','s',$q$select (public.approve_courier('{C2}',false)).approved::text$q$,'eq','false',null),
  ('pg','s',$q$select status::text||'/'||coalesce(courier_id::text,'-') from public.orders where id='{O2}'$q$,'eq','available/-',null),
  ('C2','x',$q$select public.claim_order('{O2}')$q$,'err','not_approved_courier',null),
  ('C2','x',$q$select public.report_location(24.7::float8,46.6::float8)$q$,'err','not_approved_courier',null),
  -- ---- AI: server writes, admin reviews, stale results rejected
  ('M1','x',$q$select * from public.ai_next_jobs()$q$,'err','permission denied',null),
  ('svc','s',$q$select count(*)::text||'/'||coalesce(max(current_version)::text,'-') from public.ai_next_jobs(100) where order_id='{O5}'$q$,'eq','1/0',null),
  ('M1','x',$q$select public.record_ai_result('{O5}',0,'server_model','m',array['skincare'],0.9::numeric,'r')$q$,'err','permission denied',null),
  ('svc','s',$q$select id::text from public.record_ai_result('{O5}',0,'server_model','m1',array['skincare'],0.9::numeric,'because')$q$,'ok',null,'R1'),
  ('svc','s',$q$select count(*)::text from public.ai_next_jobs(100) where order_id='{O5}'$q$,'eq','0',null),
  ('svc','x',$q$select public.record_ai_result('{O5}',0,'server_model','m1',array['skincare'],0.9::numeric,'again')$q$,'err','stale_result',null),
  ('M1','s',$q$select review_status::text from public.order_ai_current where order_id='{O5}'$q$,'eq','pending',null),
  ('M1','s',$q$select classification_status::text||'/'||cardinality(categories)::text from public.orders where id='{O5}'$q$,'eq','pending/0',null),
  ('M1','x',$q$select model from public.order_ai_results$q$,'err','permission denied',null),
  ('M2','s',$q$select count(*)::text from public.order_ai_current$q$,'eq','0',null),
  ('M1','x',$q$select public.review_ai_result('{R1}',true)$q$,'err','forbidden',null),
  ('A','x',$q$select public.review_ai_result('{R1}',true)$q$,'ok',null,null),
  ('M1','s',$q$select classification_status::text||'/'||categories::text from public.orders where id='{O5}'$q$,'eq','approved/{skincare}',null),
  ('A','x',$q$select public.review_ai_result('{R1}',true)$q$,'err','not_pending_or_stale',null),
  ('svc','s',$q$select id::text from public.record_ai_result('{O5}',1,'server_model','m2',array['perfume'],0.5::numeric,'v2')$q$,'ok',null,'R2'),
  ('M1','s',$q$select classification_status::text||'/'||categories::text from public.orders where id='{O5}'$q$,'eq','pending/{skincare}',null),
  ('svc','s',$q$select id::text from public.record_ai_result('{O5}',2,'server_model','m3',array['soap'],0.5::numeric,'v3')$q$,'ok',null,'R3'),
  ('A','s',$q$select review_status::text from public.admin_ai_results('{O5}') where version=2$q$,'eq','superseded',null),
  ('A','x',$q$select public.review_ai_result('{R2}',true)$q$,'err','not_pending_or_stale',null),
  ('A','x',$q$select public.review_ai_result('{R3}',false)$q$,'ok',null,null),
  ('M1','s',$q$select classification_status::text||'/'||categories::text from public.orders where id='{O5}'$q$,'eq','approved/{skincare}',null),
  ('svc','x',$q$select public.record_ai_result('{O5}',3,'server_model','m',array['x'],0.5::numeric,'r',false,array['other'])$q$,'err','stale_input',null),
  ('A','x',$q$update public.ai_settings set auto_approve_threshold=0.9$q$,'ok',null,null),
  ('M1','s',$q$with u2 as (update public.ai_settings set auto_approve_threshold=0.5 returning 1) select count(*)::text from u2$q$,'eq','0',null),
  ('svc','s',$q$select review_status::text from public.record_ai_result('{O5}',3,'server_model','m4',array['sunscreen'],0.95::numeric,'high confidence')$q$,'eq','auto_approved',null),
  ('M1','s',$q$select classification_status::text||'/'||categories::text from public.orders where id='{O5}'$q$,'eq','approved/{sunscreen}',null),
  ('svc','x',$q$select public.record_ai_result('{O3}',0,'server_model','m',array['a'],0.5::numeric,'r')$q$,'err','order_closed',null),
  ('A','x',$q$select public.classify_order_manually('{O5}',array[]::text[])$q$,'err','categories_required',null),
  ('M1','x',$q$select * from public.admin_ai_results()$q$,'err','forbidden',null),
  ('pg','x',$q$update public.order_ai_results set confidence=0.1 where order_id='{O5}' and version=1$q$,'err','immutable_column',null),
  -- ---- GPS cleanup
  ('pg','x',$q$insert into public.courier_location_history (courier_id,order_id,lat,lng,recorded_at) values ('{C1}',null,24.7,46.6,now()-interval '40 days')$q$,'ok',null,null),
  ('pg','x',$q$insert into public.courier_locations_latest (courier_id,order_id,lat,lng,recorded_at,updated_at) values ('{C3}',null,24.7,46.6,now(),now())$q$,'ok',null,null),
  ('M1','x',$q$select * from public.purge_courier_locations()$q$,'err','permission denied',null),
  ('svc','s',$q$select history_deleted::text||'/'||latest_deleted::text from public.purge_courier_locations()$q$,'eq','1/1',null),
  ('svc','x',$q$select * from public.purge_courier_locations(interval '1 hour')$q$,'err','retention_too_short',null),
  -- ---- misc RLS, helpers, limits
  ('M1','s',$q$select count(*)::text from public.profiles$q$,'eq','1',null),
  ('A','s',$q$select count(*)::text from public.profiles$q$,'eq','8',null),
  ('M1','s',$q$select (select count(*) from public.merchants)::text||'/'||(select count(*) from public.courier_profiles)::text$q$,'eq','1/0',null),
  ('C1','s',$q$select count(*)::text from public.notifications where user_id <> '{C1}'$q$,'eq','0',null),
  ('C1','s',$q$with u2 as (update public.notifications set read_at=now() where user_id='{M1}' returning 1) select count(*)::text from u2$q$,'eq','0',null),
  ('anon','x',$q$select public.claim_order('{O1}')$q$,'err','permission denied',null),
  ('M1','x',$q$select app_private.normalize_phone('0551234567','SA')$q$,'err','permission denied',null),
  ('pg','s',$q$select app_private.normalize_phone('0551234567','SA')$q$,'eq','+966551234567',null),
  ('pg','s',$q$select app_private.normalize_phone('966551234567','SA')$q$,'eq','+966551234567',null),
  ('pg','s',$q$select coalesce(app_private.normalize_phone('0412345678','SA'),'<null>')$q$,'eq','<null>',null),
  ('A','x',$q$update public.cities set active=false where slug='khobar'$q$,'ok',null,null),
  ('M1','x',$q$select public.create_order('{MR1}','A','0551234567',array['x'],'{RIY}','a','{KHO}','b')$q$,'err','city_not_available',null),
  ('M1','x',$q$select count(*) from (select public.create_order('{MR1}','A','0551234567',array['x'],'{RIY}','a','{RIY}','b') from generate_series(1,205)) s$q$,'err','rate_limited',null),
  -- ---- deleting an admin who reviewed AI results must work (cascade-safe guard)
  ('pg','x',$q$delete from auth.users where id='{A}'$q$,'ok',null,null),
  ('pg','s',$q$select count(*)::text from public.order_ai_results where reviewed_by is not null$q$,'eq','0',null),
  ('pg','s',$q$select case when to_regclass('cron.job') is null then 'pg_cron not enabled' else (select count(*)::text from cron.job where jobname='saai-gps-purge') end$q$,'info',null,null);

  select max(n) into v_max from pg_temp.tt;
  for v_i in 1..v_max loop
    reset role;
    select * into t from pg_temp.tt where n = v_i;
    v_sql := t.sq; v_tx := t.tx;
    for kv in select x.k, x.v from pg_temp.u x loop
      v_sql := replace(v_sql, '{' || kv.k || '}', kv.v);
      v_tx  := replace(v_tx,  '{' || kv.k || '}', kv.v);
    end loop;
    if t.who = 'pg' then
      perform set_config('request.jwt.claims', '', true); perform set_config('request.jwt.claim.sub', '', true);
    elsif t.who = 'anon' then
      perform set_config('request.jwt.claims', '{"role":"anon"}', true); perform set_config('request.jwt.claim.sub', '', true);
      execute 'set local role anon';
    elsif t.who = 'svc' then
      perform set_config('request.jwt.claims', '{"role":"service_role"}', true); perform set_config('request.jwt.claim.sub', '', true);
      execute 'set local role service_role';
    else
      select x.v into v_uid from pg_temp.u x where x.k = t.who;
      perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', v_uid, true);
      execute 'set local role authenticated';
    end if;

    v_out := null; v_ok := true; v_msg := null;
    begin
      if t.kind = 's' then execute v_sql into v_out; else execute v_sql; end if;
    exception when others then
      v_ok := false; v_msg := sqlerrm;
    end;
    reset role;

    if t.ex = 'ok' then v_pass := v_ok;
    elsif t.ex = 'eq' then v_pass := v_ok and coalesce(v_out, '<null>') = v_tx;
    elsif t.ex = 'info' then v_pass := v_ok;
    else v_pass := (not v_ok) and v_msg ilike '%' || v_tx || '%';
    end if;
    if v_pass and t.sv is not null then
      insert into pg_temp.u values (t.sv, v_out) on conflict (k) do update set v = excluded.v;
    end if;
    if v_pass then v_np := v_np + 1; else v_nf := v_nf + 1; end if;
    v_rep := v_rep || lpad(v_i::text, 3, '0') || case when v_pass then ' PASS ' else ' FAIL ' end || t.who || ' | '
             || left(regexp_replace(v_sql, '\s+', ' ', 'g'), 80)
             || case when v_pass then (case when t.ex = 'info' then ' => ' || coalesce(v_out, '<null>') else '' end) else ' || expected ' || t.ex || ':' || coalesce(v_tx, '') || ' got ok=' || v_ok::text
                  || ' out=' || coalesce(v_out, '<null>') || ' err=' || coalesce(v_msg, '-') end || E'\n';
  end loop;
  raise exception E'SAAI_TEST_REPORT PASS=% FAIL=%\n%', v_np, v_nf, v_rep;
end
$saai_test$;

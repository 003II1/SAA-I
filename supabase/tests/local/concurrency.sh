#!/usr/bin/env bash
# LOCAL concurrency tests for the SAA'I schema (real parallel connections, COMMITTED data, scratch DB only).
# usage: PGHOST=<socket dir or host> PGPORT=<port> PGUSER=postgres bash concurrency.sh
# Scratch mode only ever drops/recreates the fixed database saai_conc (the DB variable is ignored). Every mode refuses non-local hosts. Never point it at a real project.
set -u
MODE=${SAAI_MODE:-scratch}   # scratch = PG16 + stub (created here) | supabase-local = your `supabase start` database (real auth)
# scratch mode DROPS and recreates its database, so the name is FIXED and the DB environment variable is ignored.
if [ "$MODE" = "supabase-local" ]; then DB=${DB:-postgres}; else MODE=scratch; DB=saai_conc; fi
# SAFETY: local hosts only (loopback or a unix-socket directory). Applies to every mode; PGHOST must be set explicitly.
unset PGSERVICE PGSERVICEFILE PGHOSTADDR
case "${PGHOST:-}" in 127.0.0.1|localhost|/*) ;; *) echo "REFUSED: PGHOST must be 127.0.0.1, localhost or a local socket directory (got '${PGHOST:-unset}')"; exit 2;; esac
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
P="psql -X -q -At -v ON_ERROR_STOP=0"
export PGHOST PGPORT PGUSER PGPASSWORD
pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "PASS  $1 (got $3)"; pass=$((pass+1)); else echo "FAIL  $1 (expected $2, got $3)"; fail=$((fail+1)); fi; }
q(){ $P -d $DB -c "$1"; }

# as <uuid> <sql>  -> runs sql as that authenticated user (JWT claims set), prints result or ERR:<message>
as(){ local out; out=$($P -d $DB 2>&1 <<SQL
select set_config('request.jwt.claims','{"sub":"$1","role":"authenticated"}',false) \gset
set role authenticated;
$2
SQL
); if echo "$out" | grep -q "^ERROR"; then echo "ERR:$(echo "$out" | grep -m1 "^ERROR" | sed 's/^ERROR:  //')"; else echo "$out" | tail -1; fi; }
export -f as; export P DB

# ---- database
if [ "$MODE" = "supabase-local" ]; then
  # the schema must already exist (supabase db reset --local). Leaves COMMITTED test rows: run `supabase db reset --local` afterwards.
  [ "$($P -d $DB -c "select to_regclass('public.orders') is not null")" = t ] || { echo "run 'supabase db reset --local' first (public.orders missing)"; exit 2; }
else
  $P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
  $P -d $DB -v ON_ERROR_STOP=1 -f "$HERE/supabase/tests/local/00_supabase_stub.sql" >/dev/null || exit 1
  $P -d $DB -v ON_ERROR_STOP=1 -f "$HERE/supabase/migrations/20260101000000_saai_core.sql" >/dev/null 2>&1 || { echo "migration failed"; exit 1; }
fi

U(){ printf '00000000-0000-4000-8000-%012d' "$1"; }
ADMIN=$(U 1); M1=$(U 2); M2=$(U 3)
q "insert into auth.users(id,aud,role,email,raw_user_meta_data) values
  ('$ADMIN','authenticated','authenticated','a@t.invalid','{}'),
  ('$M1','authenticated','authenticated','m1@t.invalid','{\"store_name\":\"S1\"}'),
  ('$M2','authenticated','authenticated','m2@t.invalid','{\"store_name\":\"S2\"}')" >/dev/null
for i in $(seq 1 12); do
  q "insert into auth.users(id,aud,role,email,raw_user_meta_data) values ('$(U $((100+i)))','authenticated','authenticated','c$i@t.invalid','{\"role\":\"courier\"}')" >/dev/null
done
q "update public.profiles set role='admin' where id='$ADMIN'" >/dev/null
q "update public.courier_profiles set approved=true, available=true" >/dev/null
MR1=$(q "select id from public.merchants where owner_id='$M1'")
RIY=$(q "select id from public.cities where slug='riyadh'")
mkorder(){ as $M1 "select (public.create_order('$MR1','Ali','0551234567',array['x'],'$RIY','a','$RIY','b')).id;"; }

echo "== (a) two couriers claim the SAME order, 30 rounds"
bad=0
for r in $(seq 1 30); do
  O=$(mkorder)
  ( as $(U 101) "select (public.claim_order('$O')).status;" > /tmp/ca1.$$ & as $(U 102) "select (public.claim_order('$O')).status;" > /tmp/ca2.$$ & wait )
  wins=$(cat /tmp/ca1.$$ /tmp/ca2.$$ | grep -c '^assigned$')
  holders=$(q "select count(*) from public.orders where id='$O' and status='assigned' and courier_id is not null")
  [ "$wins" = 1 ] && [ "$holders" = 1 ] || bad=$((bad+1))
  # free both couriers for next round
  q "update public.orders set status='available', courier_id=null where id='$O'" >/dev/null
done
ok "(a) exactly one winner in every round (rounds with !=1 winner)" 0 $bad
O=$(mkorder)
for i in $(seq 1 10); do ( as $(U $((100+i))) "select (public.claim_order('$O')).status;" > /tmp/cb.$$.$i ) & done; wait
ok "(a) 10 couriers, one order -> winners" 1 "$(cat /tmp/cb.$$.* | grep -c '^assigned$')"
ok "(a) other 9 got order_unavailable or courier_has_active_order" 9 "$(cat /tmp/cb.$$.* | grep -Ec 'order_unavailable|courier_has_active_order')"
q "update public.orders set status='available', courier_id=null" >/dev/null

echo "== (b) ONE courier claims TWO / FIVE orders at once"
bad=0
for r in $(seq 1 20); do
  q "update public.orders set status='available', courier_id=null where status in ('assigned','picked','transit')" >/dev/null
  O1=$(mkorder); O2=$(mkorder); O3=$(mkorder)
  ( as $(U 101) "select (public.claim_order('$O1')).status;" > /tmp/cc1.$$ & as $(U 101) "select (public.claim_order('$O2')).status;" > /tmp/cc2.$$ & as $(U 101) "select (public.claim_order('$O3')).status;" > /tmp/cc3.$$ & wait )
  active=$(q "select count(*) from public.orders where courier_id='$(U 101)' and status in ('assigned','picked','transit')")
  [ "$active" = 1 ] || bad=$((bad+1))
done
ok "(b) courier never holds more than 1 active order (bad rounds)" 0 $bad

echo "== (c) admin un-approves a courier WHILE the courier claims, 30 rounds"
bad=0; claim_won=0; claim_lost=0
for r in $(seq 1 30); do
  q "update public.orders set status='available', courier_id=null where status in ('assigned','picked','transit')" >/dev/null
  q "update public.courier_profiles set approved=true, available=true where user_id='$(U 103)'" >/dev/null
  O=$(mkorder)
  ( as $(U 103) "select (public.claim_order('$O')).status;" > /tmp/cd1.$$ & as $ADMIN "select (public.approve_courier('$(U 103)', false)).approved;" > /tmp/cd2.$$ & wait )
  # invariant: an UNAPPROVED courier must never hold an assigned/picked/transit order
  if grep -q "^assigned$" /tmp/cd1.$$; then claim_won=$((claim_won+1)); else claim_lost=$((claim_lost+1)); fi
  held=$(q "select count(*) from public.orders o join public.courier_profiles cp on cp.user_id=o.courier_id where not cp.approved and o.status in ('assigned','picked','transit')")
  [ "$held" = 0 ] || bad=$((bad+1))
done
echo "      interleavings seen: claim first=$claim_won, unapprove first=$claim_lost"
ok "(c) no unapproved courier ever holds an order (bad rounds)" 0 $bad

echo "== (d) 250 PARALLEL create_order from one merchant (limit 200/hour)"
q "update public.courier_profiles set approved=true, available=true" >/dev/null
q "delete from public.orders" >/dev/null
seq 1 250 | xargs -P 40 -I{} bash -c 'as '"$M1"' "select (public.create_order('"'$MR1'"','"'Ali'"','"'0551234567'"',array['"'x'"'],'"'$RIY'"','"'a'"','"'$RIY'"','"'b'"')).id;"' > /tmp/cr.$$ 2>&1
okc=$(grep -Ec '^[0-9a-f]{8}-' /tmp/cr.$$); rl=$(grep -c 'rate_limited' /tmp/cr.$$)
ok "(d) orders stored for merchant" 200 "$(q "select count(*) from public.orders where merchant_id='$MR1'")"
ok "(d) calls that succeeded" 200 "$okc"
ok "(d) calls refused with rate_limited" 50 "$rl"

echo "== (e) parallel report_location from ONE courier (20 calls)"
q "delete from public.orders" >/dev/null   # (d) used up the merchant's hourly quota
O=$(mkorder)
case "$O" in ERR:*) echo "FAIL  (e) fixture order not created: $O"; fail=$((fail+1));; esac
as $(U 104) "select (public.claim_order('$O')).status;" >/dev/null
as $(U 104) "select public.set_location_consent(true);" >/dev/null
for i in $(seq 1 20); do ( as $(U 104) "select public.report_location(24.7136::float8, 46.6753::float8)::text;" > /tmp/ce.$$.$i ) & done; wait
ok "(e) calls that stored a point" 1 "$(cat /tmp/ce.$$.* | grep -c '^true$')"
ok "(e) others were refused (too_frequent/stale_location)" 19 "$(cat /tmp/ce.$$.* | grep -Ec 'too_frequent|stale_location')"
ok "(e) one live row for the courier" 1 "$(q "select count(*) from public.courier_locations_latest where courier_id='$(U 104)'")"
ok "(e) history rows <= 1" 1 "$(q "select count(*) from public.courier_location_history where courier_id='$(U 104)'")"

echo; echo "CONCURRENCY RESULT: PASS=$pass FAIL=$fail"
rm -f /tmp/c[a-e]*.$$* /tmp/cr.$$
[ "$fail" = 0 ]

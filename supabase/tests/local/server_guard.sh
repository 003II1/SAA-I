#!/usr/bin/env bash
# LOCAL: tests the server-only guard (app_private.is_server) from a NON-superuser login, like Supabase's authenticator.
# Needs the saai_conc database from concurrency.sh. usage: PGHOST=.. PGPORT=.. PGUSER=postgres bash server_guard.sh
set -u; export PGPASSWORD; pass=0; fail=0
if [ "${SAAI_MODE:-scratch}" = "supabase-local" ]; then DB=${DB:-postgres}; else DB=saai_conc; fi
# SAFETY: local hosts only (loopback or a unix-socket directory). Applies to every mode; PGHOST must be set explicitly.
unset PGSERVICE PGSERVICEFILE PGHOSTADDR
case "${PGHOST:-}" in 127.0.0.1|localhost|/*) ;; *) echo "REFUSED: PGHOST must be 127.0.0.1, localhost or a local socket directory (got '${PGHOST:-unset}')"; exit 2;; esac
ok(){ if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi; }
S="psql -X -q -At -d $DB"
$S -c "do \$\$ begin create role authenticator login noinherit; exception when duplicate_object then null; end \$\$; grant anon, authenticated, service_role to authenticator;" >/dev/null
run(){ PGUSER=authenticator $S 2>&1 <<SQL | grep -m1 -E "^(ERROR|[a-z0-9_/]+$)" | sed 's/^ERROR:  //'
select set_config('request.jwt.claims','$1',false) \gset
set role $2;
$3
SQL
}
O=$($S -c "select id from public.orders limit 1")
ok "authenticated (user JWT) cannot call purge (no grant)"        "permission denied for function purge_courier_locations" "$(run '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}' authenticated 'select public.purge_courier_locations();')"
ok "authenticated cannot call ai_next_jobs"                       "permission denied for function ai_next_jobs" "$(run '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}' authenticated 'select * from public.ai_next_jobs();')"
ok "authenticated cannot call record_ai_result"                   "permission denied for function record_ai_result" "$(run '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}' authenticated "select public.record_ai_result('$O',0,'server_model','m',array['x'],0.9,'r');")"
ok "anon cannot select orders"                                    "permission denied for table orders" "$(run '{"role":"anon"}' anon 'select count(*) from public.orders;')"
ok "anon cannot call claim_order"                                 "permission denied for function claim_order" "$(run '{"role":"anon"}' anon "select public.claim_order('$O');")"
ok "anon cannot call create_order"                                "permission denied for function create_order" "$(run '{"role":"anon"}' anon "select public.create_order('$O','a','b',array['x'],'$O','a','$O','b');")"
ok "anon cannot read app_private helpers"                         "permission denied for schema app_private" "$(run '{"role":"anon"}' anon 'select app_private.is_admin();')"
ok "service_role JWT: purge allowed (body guard accepts the JWT role)" "0/0/0" "$(run '{"role":"service_role"}' service_role "select history_deleted||'/'||latest_deleted||'/'||log_deleted from public.purge_courier_locations();")"
# Body guard: a role that HAS the grant but a non-service JWT must still be refused. Simulate by calling with service_role DB role + authenticated JWT claim.
ok "service_role DB role but 'authenticated' JWT: body guard refuses" "forbidden" "$(run '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}' service_role 'select public.purge_courier_locations();')"
echo "SERVER GUARD RESULT: PASS=$pass FAIL=$fail"; [ "$fail" = 0 ]

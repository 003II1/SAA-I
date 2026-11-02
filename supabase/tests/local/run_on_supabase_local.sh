#!/usr/bin/env bash
# Runs the whole R4 test set on YOUR local Supabase (Docker, PostgreSQL 17, real GoTrue/auth).
# Prerequisites: Docker running, `supabase start` done (see docs/RUN_ON_SUPABASE_LOCAL.md).
# NOT YET RUN BY THE AUTHOR against real Supabase (no Docker/network in the authoring sandbox).
# Local only: host is fixed to 127.0.0.1 and `supabase db reset` is called with --local. No cloud project or key is used.
#
# Failure handling:
#  * Essential steps (0 connect/version, 1 db reset --local, 2 migration re-run) STOP the round at the first failure.
#  * Test steps (3 harness, 4 concurrency, 5 server guards) are all run, each is judged by its exit code AND its
#    result line, and any failure makes the whole round FAIL (exit 1).
#  * No pipe is used for a step, so no exit code is hidden by tail/tee. Every result file ends with `exit=<code>`;
#    the full log of each step is kept, the screen only shows its tail. 99_summary.txt lists every step.
#  * "ALL CHECKED STEPS PASSED" is printed only if steps 0-5 all passed.
set -u -o pipefail
unset PGSERVICE PGSERVICEFILE PGHOSTADDR
cd "$(dirname "$0")/../../.." || { echo "cannot enter the repository root"; exit 1; }
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-54322} PGUSER=postgres PGPASSWORD=${PGPASSWORD:-postgres} DB=postgres SAAI_MODE=supabase-local
OUT=docs/supabase_local_results
mkdir -p "$OUT" || { echo "cannot create $OUT"; exit 1; }
P="psql -X -q -At -d $DB"
SUMMARY="$OUT/99_summary.txt"; : > "$SUMMARY"
FAILED=0

note()   { echo "$*" | tee -a "$SUMMARY"; }
record() { note "$(printf '%-30s %-5s %s' "$1" "$2" "$3")"; [ "$2" = FAIL ] && FAILED=1; return 0; }
abort()  { note ""; note "ROUND ABORTED at: $1"
           note "Nothing after this step was run. Fix the cause shown above and run the script again."
           note "Results so far are in $OUT/ (send that folder). Before a re-run: supabase db reset --local"
           exit 1; }
wait_db(){ local i; for i in $(seq 1 30); do $P -c "select 1" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

# ---- preflight ---------------------------------------------------------------------------------------------
for c in psql supabase; do
  command -v "$c" >/dev/null 2>&1 || { record "preflight" FAIL "command not found: $c"; abort "preflight"; }
done

# ---- 0. server reachable and PostgreSQL 17 ---------------------------------------------------------------
$P -c "select version()" > "$OUT/00_version.txt" 2>&1; rc=$?
echo "exit=$rc" >> "$OUT/00_version.txt"
if [ $rc -ne 0 ]; then
  cat "$OUT/00_version.txt"
  record "0 connect 127.0.0.1:$PGPORT" FAIL "exit=$rc (is 'supabase start' running?)"; abort "step 0 (connect)"
fi
pg17=$($P -c "select current_setting('server_version_num')::int >= 170000" 2>>"$OUT/00_version.txt")
echo "is_pg17=$pg17" >> "$OUT/00_version.txt"
head -1 "$OUT/00_version.txt"
if [ "$pg17" != "t" ]; then
  note "The local server is not PostgreSQL 17, so this round would not test what it is meant to test."
  note "Set [db] major_version = 17 in supabase/config.toml, then: supabase stop && supabase start"
  record "0 server is PostgreSQL 17" FAIL "is_pg17=$pg17"; abort "step 0 (version)"
fi
record "0 server is PostgreSQL 17" PASS "$(head -1 "$OUT/00_version.txt" | cut -c1-80)"

# ---- 1. fresh schema from supabase/migrations (local only) ------------------------------------------------
echo "== 1. supabase db reset --local"
supabase db reset --local > "$OUT/01_db_reset.txt" 2>&1; rc=$?
echo "exit=$rc" >> "$OUT/01_db_reset.txt"
tail -15 "$OUT/01_db_reset.txt"
if [ $rc -ne 0 ]; then
  record "1 supabase db reset --local" FAIL "exit=$rc (full log: $OUT/01_db_reset.txt)"; abort "step 1 (db reset --local)"
fi
wait_db || { record "1 reconnect after reset" FAIL "database not reachable within 30 s"; abort "step 1 (reconnect)"; }
record "1 supabase db reset --local" PASS "exit=0"

# ---- 2. the migration must be re-runnable ---------------------------------------------------------------------
echo "== 2. re-run the migration"
psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f supabase/migrations/20260101000000_saai_core.sql > "$OUT/02_rerun.txt" 2>&1; rc=$?
echo "exit=$rc" >> "$OUT/02_rerun.txt"
if [ $rc -ne 0 ]; then
  tail -15 "$OUT/02_rerun.txt"
  record "2 migration re-run" FAIL "exit=$rc (full log: $OUT/02_rerun.txt)"; abort "step 2 (migration re-run)"
fi
record "2 migration re-run" PASS "exit=0"

# ---- 3. SQL test harness -------------------------------------------------------------------------------------------
# The harness ends with a DELIBERATE exception "SAAI_TEST_REPORT PASS=n FAIL=m" (it rolls everything back and delivers the
# report as the error text). With ON_ERROR_STOP=1 psql therefore exits 3 on a correct run. The step passes only if ALL hold:
#   rc = 3, the FIRST error line is that deliberate exception (not another SQL error), PASS > 0, FAIL = 0.
echo "== 3. harness"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f supabase/tests/saai_core_tests.sql > "$OUT/03_harness.txt" 2>&1; rc=$?
echo "exit=$rc" >> "$OUT/03_harness.txt"
first_err=$(grep -m1 "ERROR:" "$OUT/03_harness.txt")
rep=$(printf '%s\n' "$first_err" | grep -o "SAAI_TEST_REPORT PASS=[0-9]* FAIL=[0-9]*" | head -1)
if [ -z "$rep" ]; then
  head -20 "$OUT/03_harness.txt" | cut -c1-300
  record "3 harness" FAIL "first error is not the SAAI_TEST_REPORT exception (psql exit=$rc) - see $OUT/03_harness.txt"
else
  hp=${rep#*PASS=}; hp=${hp%% *}; hf=${rep##*FAIL=}
  grep " FAIL " "$OUT/03_harness.txt" | cut -c1-300
  if [ $rc -eq 3 ] && [ "$hf" = 0 ] && [ "$hp" -gt 0 ]; then
    record "3 harness" PASS "$rep (psql exit=3 = the deliberate report exception)"
    [ "$hp" = 180 ] || note "   note: 180 tests passed on PostgreSQL 16; this run reports PASS=$hp - check that the test file is the expected one"
  else
    record "3 harness" FAIL "$rep but psql exit=$rc (expected 3) FAIL=$hf PASS=$hp - see $OUT/03_harness.txt"
  fi
fi

# ---- 4. real concurrency (committed rows; run `supabase db reset --local` afterwards) -----------------------
echo "== 4. concurrency"
bash supabase/tests/local/concurrency.sh > "$OUT/04_concurrency.txt" 2>&1; rc=$?
echo "exit=$rc" >> "$OUT/04_concurrency.txt"
tail -25 "$OUT/04_concurrency.txt"
res=$(grep -o "CONCURRENCY RESULT: PASS=[0-9]* FAIL=[0-9]*" "$OUT/04_concurrency.txt" | head -1)
if [ $rc -eq 0 ] && [ -n "$res" ] && [ "${res##*FAIL=}" = 0 ]; then
  record "4 concurrency" PASS "$res"
else
  record "4 concurrency" FAIL "exit=$rc ${res:-no result line} - see $OUT/04_concurrency.txt"
fi

# ---- 5. server-only guards from the real 'authenticator' login -----------------------------------------------
echo "== 5. server-only guards"
bash supabase/tests/local/server_guard.sh > "$OUT/05_server_guard.txt" 2>&1; rc=$?
echo "exit=$rc" >> "$OUT/05_server_guard.txt"
tail -12 "$OUT/05_server_guard.txt"
res=$(grep -o "SERVER GUARD RESULT: PASS=[0-9]* FAIL=[0-9]*" "$OUT/05_server_guard.txt" | head -1)
if [ $rc -eq 0 ] && [ -n "$res" ] && [ "${res##*FAIL=}" = 0 ]; then
  record "5 server guards" PASS "$res"
else
  record "5 server guards" FAIL "exit=$rc ${res:-no result line} - see $OUT/05_server_guard.txt"
fi

# ---- 6. information only: never fails the round -------------------------------------------------------------
$P -c "select 'schemas exposed to API: '||coalesce(current_setting('pgrst.db_schemas', true),'(not visible from SQL - check [api] schemas in supabase/config.toml)')" > "$OUT/06_api.txt" 2>&1
echo "exit=$?" >> "$OUT/06_api.txt"
head -1 "$OUT/06_api.txt"
record "6 API exposure (info only)" INFO "$(head -1 "$OUT/06_api.txt" | cut -c1-90)"

# ---- verdict -------------------------------------------------------------------------------------------------------
note ""
if [ $FAILED -ne 0 ]; then
  note "ROUND FAILED - do not treat this as a pass. Send the folder $OUT/ (plain text, no keys)."
  note "Then clean up the committed concurrency rows:  supabase db reset --local"
  exit 1
fi
note "ALL CHECKED STEPS PASSED (0-5): PostgreSQL 17 + real auth, harness, concurrency, server guards."
note "Still NOT tested: PostgREST with real JWTs, connection pooler, performance."
note "Now run:  supabase db reset --local   (removes the committed concurrency rows)"
note "Send back the folder $OUT/ (plain text, contains no keys)."
exit 0

#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the upstream test suites that mayhem/build.sh produced.
#
# Suites integrated (upstream CI, .github/workflows/main.yml):
#   * Go implementation  (go/olc_test.go) — the fuzzed code path. Pre-built by
#     build.sh as mayhem-build/olc-go.test (go test -c); run here with -test.v
#     and counted from the --- PASS/FAIL/SKIP lines. Known-answer tests driven
#     by the shared CSVs in test_data/.
#   * Python implementation (python/openlocationcode_test.py) — stdlib unittest,
#     runs directly from the source tree against the same test_data/ CSVs.
# NOT integrated (see repos/open-location-code.yaml notes): the C, C++, Java,
# JS, Ruby, Rust, Dart, VB and PL/pgSQL suites — each needs its own toolchain
# (bazel, JDK, node, ruby, cargo, dart, PostgreSQL) that is not in the commit
# image and cannot be cached air-gapped without bloating it; the fuzzed
# implementation (Go) and the Python suite are run in full.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASS=0; FAIL=0; SKIP=0

# ---- Go suite (pre-built runner; do NOT compile here) -------------------------
GO_TEST_BIN="$SRC/mayhem-build/olc-go.test"
if [ ! -x "$GO_TEST_BIN" ]; then
  echo "FATAL: $GO_TEST_BIN missing — mayhem/build.sh must pre-build the Go test runner" >&2
  emit_ctrf "go-test+py-unittest" 0 1 0
  exit 1
fi
go_log="$(mktemp)"
( cd "$SRC/go" && "$GO_TEST_BIN" -test.v ) >"$go_log" 2>&1
go_rc=$?
sed 's/^/[go] /' "$go_log"
gp=$(grep -c '^--- PASS' "$go_log" || true)
gf=$(grep -c '^--- FAIL' "$go_log" || true)
gs=$(grep -c '^--- SKIP' "$go_log" || true)
# A runner that dies before reporting (or reports nothing) is a failure.
if [ "$go_rc" -ne 0 ] && [ "$gf" -eq 0 ]; then gf=1; fi
if [ $(( gp + gf + gs )) -eq 0 ]; then gf=1; fi
PASS=$(( PASS + gp )); FAIL=$(( FAIL + gf )); SKIP=$(( SKIP + gs ))
echo "go suite: passed=$gp failed=$gf skipped=$gs (rc=$go_rc)"

# ---- Python suite (stdlib unittest, runs from the source tree) ----------------
py_log="$(mktemp)"
( cd "$SRC" && python3 -m unittest -v python.openlocationcode_test ) >"$py_log" 2>&1
py_rc=$?
sed 's/^/[py] /' "$py_log"
pp=$(grep -c ' \.\.\. ok$' "$py_log" || true)
pf=$(grep -cE ' \.\.\. (FAIL|ERROR)$' "$py_log" || true)
ps=$(grep -c ' \.\.\. skipped' "$py_log" || true)
if [ "$py_rc" -ne 0 ] && [ "$pf" -eq 0 ]; then pf=1; fi
if [ $(( pp + pf + ps )) -eq 0 ]; then pf=1; fi
PASS=$(( PASS + pp )); FAIL=$(( FAIL + pf )); SKIP=$(( SKIP + ps ))
echo "python suite: passed=$pp failed=$pf skipped=$ps (rc=$py_rc)"

emit_ctrf "go-test+py-unittest" "$PASS" "$FAIL" "$SKIP"

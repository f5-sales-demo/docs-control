#!/usr/bin/env bash
# Behavioural tests for the inlined retry() helper (issue #805).
#
# retry() is used in ~23 places whose stdout is captured into a variable, several
# of which drive enforcement decisions. If a failed attempt's stdout reaches the
# caller, the captured value is silently wrong rather than absent — so these tests
# assert isolation, not just exit codes.
#
# The helper is extracted from the workflows themselves rather than from a fixture,
# so the test always exercises the code that actually ships. The commands under
# retry are real executables rather than shell functions, matching how retry is
# used in production (it wraps `gh`).
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1 — $2"
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SHA="13e86d50da58d9dc54080f41d56ac804a5cb49e8"
ERR_BODY='{"message":"Not Found","status":"404"}'

# Fails once — printing an error object to stdout, exactly as `gh api` does — then
# succeeds. This is the shape that corrupted ref_sha in production.
FLAKY="${TMPDIR_BASE}/flaky"
cat >"$FLAKY" <<EOF
#!/usr/bin/env bash
if [ ! -f "\$1" ]; then
  touch "\$1"
  echo '${ERR_BODY}'
  exit 1
fi
echo "${SHA}"
EOF

OK="${TMPDIR_BASE}/ok"
printf '#!/usr/bin/env bash\necho "plain-output"\n' >"$OK"

MULTI="${TMPDIR_BASE}/multi"
printf '#!/usr/bin/env bash\nprintf "line1\\nline2\\n"\n' >"$MULTI"

ALWAYS="${TMPDIR_BASE}/always"
cat >"$ALWAYS" <<EOF
#!/usr/bin/env bash
echo '${ERR_BODY}'
exit 1
EOF

chmod +x "$FLAKY" "$OK" "$MULTI" "$ALWAYS"

# Pull the retry() definition out of a workflow and make it callable here.
extract_retry() {
  awk '/^[[:space:]]*retry\(\)[[:space:]]*\{/,/^[[:space:]]*\}[[:space:]]*$/' "$1" |
    sed -e 's/^[[:space:]]\{10\}//'
}

WORKFLOWS=(
  "${REPO_ROOT}/.github/workflows/sync-managed-files.yml"
  "${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml"
)

for wf in "${WORKFLOWS[@]}"; do
  name=$(basename "$wf")
  echo ""
  echo "=== retry() from ${name} ==="

  body=$(extract_retry "$wf")
  if [ -z "$body" ]; then
    fail "${name}: retry() is extractable" "no retry() definition found"
    continue
  fi
  pass "${name}: retry() is extractable"

  # Each case runs in its own subshell so the eval'd helper and the marker file
  # cannot leak between them.
  marker="${TMPDIR_BASE}/marker-$$-${RANDOM}"

  # 1. Fail-then-succeed must yield ONLY the successful output.
  captured=$(
    eval "$body"
    retry 3 "$FLAKY" "$marker" 2>/dev/null
  )
  rm -f "$marker"
  if [ "$captured" = "$SHA" ]; then
    pass "${name}: failed attempt's stdout is discarded"
  else
    fail "${name}: failed attempt's stdout is discarded" \
      "captured $(printf '%q' "$captured") — a failed attempt leaked into the value"
  fi

  # 2. The happy path must be untouched.
  captured=$(
    eval "$body"
    retry 3 "$OK" 2>/dev/null
  )
  if [ "$captured" = "plain-output" ]; then
    pass "${name}: successful output passes through unchanged"
  else
    fail "${name}: successful output passes through unchanged" "captured $(printf '%q' "$captured")"
  fi

  # 3. Multi-line output must survive intact — several call sites capture whole
  #    JSON bodies.
  captured=$(
    eval "$body"
    retry 3 "$MULTI" 2>/dev/null
  )
  if [ "$captured" = "$(printf 'line1\nline2')" ]; then
    pass "${name}: multi-line success output is preserved"
  else
    fail "${name}: multi-line success output is preserved" "captured $(printf '%q' "$captured")"
  fi

  # 4. Total failure must return non-zero and emit no stdout, so a caller guarding
  #    on emptiness sees emptiness rather than an error body.
  rc=0
  captured=$(
    eval "$body"
    retry 2 "$ALWAYS" 2>/dev/null
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "${name}: exhausted retries return non-zero"
  else
    fail "${name}: exhausted retries return non-zero" "returned 0"
  fi
  if [ -z "$captured" ]; then
    pass "${name}: exhausted retries emit no stdout"
  else
    fail "${name}: exhausted retries emit no stdout" "captured $(printf '%q' "$captured")"
  fi
done

# ════════════════════════════════════════════════════════════════════
# http_status(): the counterpart to retry()'s stdout isolation
# ════════════════════════════════════════════════════════════════════
# Enabling GitHub Pages for the first time depends on reading `404` from a call
# that FAILS. retry() withholds a failed attempt's stdout by design, so these
# probes must not use it — otherwise the status comes back empty, the 404 branch
# is skipped, and enforcement PUTs against a Pages site that does not exist yet.
echo ""
echo "=== http_status() from enforce-repo-settings.yml ==="

ENFORCE_WF="${REPO_ROOT}/.github/workflows/enforce-repo-settings.yml"

status_body=$(awk '/^[[:space:]]*http_status\(\)[[:space:]]*\{/,/^[[:space:]]*\}[[:space:]]*$/' "$ENFORCE_WF" |
  sed -e 's/^[[:space:]]\{10\}//')

if [ -z "$status_body" ]; then
  fail "http_status() is extractable" "no http_status() definition found"
else
  pass "http_status() is extractable"

  # Fake `gh` that behaves like the real one against a repo with no Pages site:
  # prints the response (headers included) to stdout, exits non-zero.
  FAKE_BIN="${TMPDIR_BASE}/bin"
  mkdir -p "$FAKE_BIN"
  cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
exit 1
EOF
  chmod +x "${FAKE_BIN}/gh"

  captured=$(
    export PATH="${FAKE_BIN}:${PATH}"
    eval "$status_body"
    http_status "repos/o/r/pages"
  )
  if [ "$captured" = "404" ]; then
    pass "http_status reads 404 from a failing call (first-time Pages enablement)"
  else
    fail "http_status reads 404 from a failing call (first-time Pages enablement)" \
      "captured $(printf '%q' "$captured") — the 404 branch would be skipped"
  fi

  # A transient transport failure (no HTTP status at all) must be retried, and the
  # 404 that follows must still be reported — this is the case that decides whether
  # first-time Pages enablement takes the create path.
  cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
marker="${TMPDIR:-/tmp}/http-status-transient-marker"
if [ ! -f "$marker" ]; then
  touch "$marker"
  exit 1          # no stdout at all: request never reached GitHub
fi
printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
exit 1
EOF
  chmod +x "${FAKE_BIN}/gh"
  rm -f "${TMPDIR:-/tmp}/http-status-transient-marker"
  captured=$(
    export PATH="${FAKE_BIN}:${PATH}"
    eval "$status_body"
    http_status "repos/o/r/pages" 2>/dev/null
  )
  rm -f "${TMPDIR:-/tmp}/http-status-transient-marker"
  if [ "$captured" = "404" ]; then
    pass "http_status retries a transport failure and still reports the 404"
  else
    fail "http_status retries a transport failure and still reports the 404" \
      "captured $(printf '%q' "$captured")"
  fi

  # A persistent transport failure must yield nothing and a non-zero status, so the
  # caller skips the phase instead of guessing between create and update.
  printf '#!/usr/bin/env bash\nexit 1\n' >"${FAKE_BIN}/gh"
  chmod +x "${FAKE_BIN}/gh"
  rc=0
  captured=$(
    export PATH="${FAKE_BIN}:${PATH}"
    eval "$status_body"
    http_status "repos/o/r/pages" 2>/dev/null
  ) || rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$captured" ]; then
    pass "http_status reports unknown (non-zero, no output) when status never arrives"
  else
    fail "http_status reports unknown (non-zero, no output) when status never arrives" \
      "rc=$rc captured=$(printf '%q' "$captured")"
  fi

  # A transient 5xx must be retried, not accepted as the answer: taking it would
  # read as "not 404" and send the caller down the update path.
  cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
marker="${TMPDIR:-/tmp}/http-status-5xx-marker"
if [ ! -f "$marker" ]; then
  touch "$marker"
  printf 'HTTP/2.0 500 Internal Server Error\n\n'
  exit 1
fi
printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
exit 1
EOF
  chmod +x "${FAKE_BIN}/gh"
  rm -f "${TMPDIR:-/tmp}/http-status-5xx-marker"
  captured=$(
    export PATH="${FAKE_BIN}:${PATH}"
    eval "$status_body"
    http_status "repos/o/r/pages" 2>/dev/null
  )
  rm -f "${TMPDIR:-/tmp}/http-status-5xx-marker"
  if [ "$captured" = "404" ]; then
    pass "http_status retries a transient 5xx and reports the eventual 404"
  else
    fail "http_status retries a transient 5xx and reports the eventual 404" \
      "captured $(printf '%q' "$captured")"
  fi

  # A persistent 5xx must end as unknown rather than being reported as a status.
  printf '#!/usr/bin/env bash\nprintf "HTTP/2.0 503 Service Unavailable\\n\\n"\nexit 1\n' >"${FAKE_BIN}/gh"
  chmod +x "${FAKE_BIN}/gh"
  rc=0
  captured=$(
    export PATH="${FAKE_BIN}:${PATH}"
    eval "$status_body"
    http_status "repos/o/r/pages" 2>/dev/null
  ) || rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$captured" ]; then
    pass "http_status treats a persistent 5xx as unknown, not as an answer"
  else
    fail "http_status treats a persistent 5xx as unknown, not as an answer" \
      "rc=$rc captured=$(printf '%q' "$captured")"
  fi

  # A 429 must not be retried inside the embargo, and must not be reported as an
  # answer either — the caller declines to act this run.
  printf '#!/usr/bin/env bash\nprintf "HTTP/2.0 429 Too Many Requests\\n\\n"\nexit 1\n' >"${FAKE_BIN}/gh"
  chmod +x "${FAKE_BIN}/gh"
  rc=0
  captured=$(
    export PATH="${FAKE_BIN}:${PATH}"
    eval "$status_body"
    http_status "repos/o/r/pages" 2>/dev/null
  ) || rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$captured" ]; then
    pass "http_status reports unknown on 429 without retrying into the embargo"
  else
    fail "http_status reports unknown on 429 without retrying into the embargo" \
      "rc=$rc captured=$(printf '%q' "$captured")"
  fi

  # And a healthy 200 still parses.
  cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2.0 200 OK\n\n{"build_type":"workflow"}\n'
EOF
  chmod +x "${FAKE_BIN}/gh"
  captured=$(
    export PATH="${FAKE_BIN}:${PATH}"
    eval "$status_body"
    http_status "repos/o/r/pages"
  )
  if [ "$captured" = "200" ]; then
    pass "http_status reads 200 from a successful call"
  else
    fail "http_status reads 200 from a successful call" "captured $(printf '%q' "$captured")"
  fi
fi

# An unverifiable Pages state must fail the run. Warning-only would let the
# workflow print "All settings verified successfully" having verified nothing.
if awk '/VERIFY_PAGES_CODE=/,/elif \[ "\$VERIFY_PAGES_CODE" = "404" \]/' "$ENFORCE_WF" | grep -q 'VERIFY_FAILED=true'; then
  pass "unknown Pages status fails verification"
else
  fail "unknown Pages status fails verification" "unknown status does not set VERIFY_FAILED"
fi

# The probes must stay off retry(), or the regression returns silently.
if grep -qE 'retry [0-9]+ gh api .*--include' "$ENFORCE_WF"; then
  fail "status probes do not use retry()" "a --include probe is still wrapped in retry"
else
  pass "status probes do not use retry()"
fi

echo ""
echo "════════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed ($((PASS + FAIL)) total)"
echo "════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]

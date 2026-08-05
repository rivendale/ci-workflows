#!/usr/bin/env bash
# Exercises the panel's "did the reviewer actually run?" logic against fixtures.
# The logic under test is extracted verbatim from the Review step so a change
# there that this file does not also get is a change that was never tested.
set -uo pipefail

WF=${1:-"$(dirname "$0")/../.github/workflows/ai-review.yml"}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Pull the decision block out of the workflow: from `reviewer_failed=` to the
# line before the composition `if`. Dedents by the step's 10-space indent.
sed -n '/^          reviewer_failed=$/,/^          fi$/p' "$WF" \
  | sed 's/^          //' > "$WORK/detector.sh"
[ -s "$WORK/detector.sh" ] || { echo "FAIL: could not extract the detector"; exit 1; }

pass=0; fail=0
check() { # name expected exit_code stdout stderr [login_status] [reason_substring]
  # The reason matters as much as the verdict: "no OPENAI_API_KEY on this repo"
  # and "the reviewer produced no review" are both failures, but only one tells
  # you what to do, and a check that conflated them would look tested here
  # while giving the wrong answer in every repo missing the key.
  local name=$1 expected=$2 code=$3 out=$4 err=$5 login=${6:-0} want=${7:-}
  # codex_status and the two files ARE the detector's inputs. It is sourced at
  # a computed path, so the linter can neither see the use nor follow it.
  # shellcheck disable=SC2034,SC1091
  ( cd "$WORK" && printf '%s' "$out" > verdict.md && printf '%s' "$err" > transcript.md \
    && codex_status=$code && login_status=$login && . ./detector.sh \
    && printf '%s' "$reviewer_failed" > reason \
    && if [ -n "$reviewer_failed" ]; then echo FAILED; else echo RAN; fi ) > "$WORK/got" 2>/dev/null
  local got reason; got=$(cat "$WORK/got"); reason=$(cat "$WORK/reason" 2>/dev/null || true)
  if [ "$got" != "$expected" ]; then
    fail=$((fail + 1)); printf '  NOT OK %s -- expected %s, got %s\n' "$name" "$expected" "$got"
  elif [ -n "$want" ] && [[ "$reason" != *"$want"* ]]; then
    fail=$((fail + 1)); printf '  NOT OK %s -- reason should mention %s, said: %s\n' "$name" "$want" "$reason"
  else
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  fi
}

# The panel's own error-pattern vocabulary, as the reviewer would print it when
# reviewing a PR that edits this workflow. This is the regression that started
# all of it: a correct review that the panel called broken.
# Literal on purpose: this is what the reviewer printed, `$codex_status` and
# all, and expanding it would defeat the fixture.
# shellcheck disable=SC2016
SELF_TEXT='exec
/bin/bash -lc "diff -u /tmp/old.yml /tmp/new.yml" in /home/runner/work/repo/repo
 succeeded in 263ms:
+          if [ "$codex_status" -ne 0 ] \
+             || grep -qE "401 Unauthorized|Reconnecting\.\.\.|failed to connect|bwrap:|Unable to inspect" raw-review.md; then
+            echo "reviewer_failed=true" >> "$GITHUB_OUTPUT"

codex
The workflow reference was updated consistently.'

echo "Detector fixtures:"
check "clean review"                RAN    0 "Looks fine to me." "banner
exec
 succeeded"
check "review with P1 findings"     RAN    0 "- [P1] Compare tokens with strict equality
  Loose equality accepts coerced values." "banner"
check "PR that edits this workflow" RAN    0 "The workflow reference was updated consistently." "$SELF_TEXT"
check "auth failure, non-zero exit" FAILED 1 "" "stream error: 401 Unauthorized"
check "no verdict, exit 0"          FAILED 0 "" "banner
exec
 succeeded"
check "whitespace-only verdict"     FAILED 0 "

" "banner"
# Isolates the exit code: stdout is non-empty, so only the exit check can
# catch it. Without this the exit-code branch is dead weight no test covers.
check "partial verdict then a crash" FAILED 1 "The change looks" "banner
stream error: connection reset"
# A repo with no OPENAI_API_KEY. Login fails, the review never runs, and the
# panel has to say which secret is missing rather than die on a missing file.
check "no key on the repo"          FAILED 0 "" "" 1 "OPENAI_API_KEY"

echo
echo "Mutations (each MUST break at least one fixture):"
mutate() { # name sed-expression
  local name=$1 expr=$2
  local mwf="$WORK/mutant.yml"
  sed "$expr" "$WF" > "$mwf"
  if cmp -s "$mwf" "$WF"; then
    echo "  NOT OK $name -- mutation did not change the file"; fail=$((fail + 1)); return
  fi
  local before=$fail
  # The counters are deliberately subshell-local: the mutant run must not
  # pollute the real tally, which is why its result comes back through stdout
  # as MUTANTFAIL rather than through a variable.
  local quiet
  # shellcheck disable=SC2030
  quiet=$( { pass=0; fail=0
    sed -n '/^          reviewer_failed=$/,/^          fi$/p' "$mwf" | sed 's/^          //' > "$WORK/detector.sh"
    [ -s "$WORK/detector.sh" ] || { echo "detector gone"; exit 1; }
    check "clean review"                RAN    0 "Looks fine to me." "banner"
    check "PR that edits this workflow" RAN    0 "Fine." "$SELF_TEXT"
    check "auth failure, non-zero exit" FAILED 1 "" "401 Unauthorized"
    check "no verdict, exit 0"          FAILED 0 "" "banner"
    check "whitespace-only verdict"     FAILED 0 "   " "banner"
    check "partial verdict then a crash" FAILED 1 "The change looks" "banner"
    check "no key on the repo"          FAILED 0 "" "" 1 "OPENAI_API_KEY"
    echo "MUTANTFAIL=$fail"; } 2>&1 )
  fail=$before
  local mfail; mfail=$(printf '%s' "$quiet" | sed -n 's/.*MUTANTFAIL=//p')
  # shellcheck disable=SC2031
  if [ "${mfail:-0}" -gt 0 ]; then
    printf '  ok    %s -- caught (%s fixture(s) broke)\n' "$name" "$mfail"; pass=$((pass + 1))
  else
    printf '  NOT OK %s -- SURVIVED; the fixtures do not test this\n' "$name"; fail=$((fail + 1))
  fi
}

# These are sed scripts, not shell expansions.
# shellcheck disable=SC2016
mutate "ignore the exit code"        's/if \[ "\$codex_status" -ne 0 \]; then/if false; then/'
mutate "ignore an empty verdict"     's/elif ! grep -q .\[^\[:space:\]\]. verdict.md; then/elif false; then/'
mutate "accept a whitespace-only verdict" \
  "s|elif ! grep -q '\\[^\\[:space:\\]\\]' verdict.md; then|elif [ ! -s verdict.md ]; then|"
# These are sed scripts, not shell expansions.
# shellcheck disable=SC2016
mutate "ignore a failed login"       's/if \[ "\$login_status" -ne 0 \]; then/if false; then/'
mutate "grep the transcript again (the original bug)" \
  's|elif ! grep -q .\[^\[:space:\]\]. verdict.md; then|elif grep -qE "401 Unauthorized\|bwrap:" transcript.md; then|'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

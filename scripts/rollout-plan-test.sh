#!/usr/bin/env bash
# Exercises plan_for, the rollout's "where does this repo's caller go, and what
# state is it in" decision.
#
# It gets its own tests because it has produced two real bugs already: it
# opened a duplicate caller beside a working one, and it classified any
# workflow containing "uses:" as a caller -- which is every workflow, via
# actions/checkout -- so the apply path would have overwritten unrelated CI.
#
# The function is sourced from the rollout script rather than restated, so a
# change there that this file does not cover is a change that was never tested.
set -uo pipefail

SCRIPT=${1:-"$(dirname "$0")/rollout-ai-review.sh"}
# Set when this script re-invokes itself to score a mutant. The child must run
# the FIXTURES ONLY: if it also ran the mutation section, each already-applied
# mutation would report "did not change the file", and the parent -- which
# decides by looking for NOT OK -- would read that as a broken fixture and
# call an ineffective mutation caught.
FIXTURES_ONLY=${FIXTURES_ONLY:-}
HOST=rivendale/ci-workflows
WORKFLOW=.github/workflows/ai-review.yml
SELF_WORKFLOW=.github/workflows/self-review.yml

# Pull in is_caller/is_host_caller/plan_for without running the rollout.
eval "$(sed -n '/^job_uses()/,/^}$/p'        "$SCRIPT")"
eval "$(sed -n '/^is_caller()/,/^}$/p'      "$SCRIPT")"
eval "$(sed -n '/^is_host_caller()/,/^}$/p' "$SCRIPT")"
eval "$(sed -n '/^plan_for()/,/^}$/p'       "$SCRIPT")"
declare -F plan_for >/dev/null || { echo "FAIL: could not load plan_for"; exit 1; }

# Fixture content, keyed by "<repo> <path>". file_at is stubbed to read it, so
# no network and no gh.
declare -A FILES
file_at() { printf '%s' "${FILES["$1 $2"]:-}"; }

CALLER_HOST="jobs:
  panel:
    uses: $HOST/.github/workflows/ai-review.yml@main"
CALLER_OLD="jobs:
  panel:
    uses: rivendale/rygiel-shared/.github/workflows/ai-review.yml@main"
PANEL="on:
  workflow_call:
jobs:
  review:
    steps:
      - uses: actions/checkout@v4"
# The heart of it: an unrelated workflow that happens to contain 'uses:'.
UNRELATED="name: Self review reminder
on: [pull_request]
jobs:
  remind:
    steps:
      - uses: actions/checkout@v4
      - run: echo hi"

pass=0; fail=0
check() { # name repo expected
  local name=$1 repo=$2 expected=$3 got
  got=$(plan_for "$repo")
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  NOT OK %s\n         expected: %s\n         got:      %s\n' "$name" "$expected" "$got"
  fi
}

echo "plan_for fixtures:"

FILES=( ["a $WORKFLOW"]="$CALLER_HOST" )
check "already on the public host"        a "$WORKFLOW wired"

FILES=( ["b $SELF_WORKFLOW"]="$CALLER_HOST" ["b $WORKFLOW"]="$PANEL" )
check "panel repo, caller at self-review" b "$SELF_WORKFLOW wired"

# rygiel-shared after its panel was deleted: ai-review.yml absent, a working
# caller at self-review.yml. Must NOT propose adding a second one.
FILES=( ["c $SELF_WORKFLOW"]="$CALLER_HOST" )
check "caller at self-review, no panel"   c "$SELF_WORKFLOW wired"

FILES=( ["d $WORKFLOW"]="$CALLER_OLD" )
check "still on the old private host"     d "$WORKFLOW repoint"

FILES=()
check "empty repo"                        e "$WORKFLOW add"

FILES=( ["f $WORKFLOW"]="$PANEL" )
check "hosts a panel, self-review free"   f "$SELF_WORKFLOW add"

# The clobber cases. Neither may resolve to a path the apply path would write.
FILES=( ["g $SELF_WORKFLOW"]="$UNRELATED" )
check "unrelated self-review, no caller"  g "$WORKFLOW add"

FILES=( ["h $WORKFLOW"]="$PANEL" ["h $SELF_WORKFLOW"]="$UNRELATED" )
check "both names taken by non-callers"   h "- blocked"

FILES=( ["i $WORKFLOW"]="$UNRELATED" )
check "unrelated ai-review.yml"           i "$SELF_WORKFLOW add"

# A file that only MENTIONS a caller, in a comment and in a run: block. An
# unanchored text match called this a caller and would have overwritten it.
MENTIONS="name: Notes
# previous caller: uses: other/team/.github/workflows/ai-review.yml@main
on: [pull_request]
jobs:
  note:
    steps:
      - run: echo 'uses: other/team/.github/workflows/ai-review.yml@main'"
FILES=( ["j $WORKFLOW"]="$MENTIONS" )
check "merely mentions a caller"          j "$SELF_WORKFLOW add"

# Valid YAML, just more whitespace after the key. A pattern demanding exactly
# one space missed this and would have added a SECOND caller alongside it.
SPACED="jobs:
  panel:
    uses:    rivendale/rygiel-shared/.github/workflows/ai-review.yml@main"
FILES=( ["k $WORKFLOW"]="$SPACED" )
check "caller with extra whitespace"      k "$WORKFLOW repoint"

# Not parseable. Must not be mistaken for a caller, and must not be written over.
FILES=( ["l $WORKFLOW"]="{{ this is not yaml" ["l $SELF_WORKFLOW"]="{{ nor is this" )
check "unparseable on both names"         l "- blocked"

if [ -n "$FIXTURES_ONLY" ]; then
  printf 'passed %d, failed %d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

echo
echo "Mutations:"
mutate() { # name sed-expression [caught|survives]
  local name=$1 expr=$2 want=${3:-caught} mutant out
  mutant=$(mktemp); sed "$expr" "$SCRIPT" > "$mutant"
  if cmp -s "$mutant" "$SCRIPT"; then
    echo "  NOT OK $name -- mutation did not change the file"; fail=$((fail + 1)); rm -f "$mutant"; return
  fi
  out=$(FIXTURES_ONLY=1 "$0" "$mutant" 2>&1)
  rm -f "$mutant"
  local got=caught
  printf '%s' "$out" | grep -q "NOT OK" || got=survives
  if [ "$got" = "$want" ]; then
    printf '  ok    %s -- %s\n' "$name" "$got"; pass=$((pass + 1))
  elif [ "$want" = caught ]; then
    printf '  NOT OK %s -- SURVIVED; the fixtures do not test this\n' "$name"; fail=$((fail + 1))
  else
    printf '  NOT OK %s -- was caught, but this mutation changes no behaviour;\n         the harness is reporting failures that are not there\n' "$name"; fail=$((fail + 1))
  fi
}

# These are sed scripts, not shell expansions.
# shellcheck disable=SC2016
# Go back to grepping the raw file instead of the parsed jobs. That is what
# made a comment mentioning a caller look like one. '#' delimits because the
# line contains a shell pipe.
mutate "grep the raw text, not parsed jobs" \
  's#^  job_uses "$1" | grep#  printf "%s" "$1" | grep#'
# The bug that opened a duplicate caller: ignore self-review.yml entirely.
# These are sed scripts, not shell expansions.
# shellcheck disable=SC2016
mutate "ignore an existing self-review caller" \
  's|elif is_host_caller "\$self_body"; then|elif false; then|'
# Removing the blocked state means clobbering unrelated CI.
# shellcheck disable=SC2016
mutate "overwrite when both names are taken" \
  's|^    echo "- blocked"|    echo "$SELF_WORKFLOW add"|'

# Negative control. Editing a comment cannot change a decision, so this MUST
# survive. If it is reported caught, the harness is manufacturing failures and
# every "caught" above is worthless.
mutate "a comment change (control)" \
  's|^# Decides where this repo|# DECIDES where this repo|' survives

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

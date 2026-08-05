#!/usr/bin/env bash
# Wires the central AI review panel into repos, and repoints any repo still
# calling the panel's old private home.
#
#   OPENAI_API_KEY=sk-... ./scripts/rollout-ai-review.sh          # dry run
#   OPENAI_API_KEY=sk-... ./scripts/rollout-ai-review.sh --apply
#
# Opens one PR per repo and sets the per-repo secret. Per-repo because
# `rivendale` is a personal account, so there are no organisation-level Actions
# secrets.
#
# The panel lives in a PUBLIC repo on purpose. A public repository cannot call
# a reusable workflow that lives in a private one, and the split was exact when
# the panel was private: all five private repos worked, all five public ones
# failed at startup. Nothing in the panel is sensitive; it is CI logic.
#
# Excluded on purpose:
#   - the PRIVATE Protocol Wealth repos; reviewed under a separate process
#   - forks (OpenBBTerminal, TinyTroupe, tank-royale); upstream code, not ours
#   - archived repos
#
# `pwgraph-core` IS in scope despite the prefix. It is the family brain behind
# brain.rygiel.family, lives in this personal account, and is personal/family
# only -- it is not a Protocol Wealth repo. Do not drop it for matching "pw".
set -euo pipefail

APPLY=${1:-}
HOST=rivendale/ci-workflows
WORKFLOW=.github/workflows/ai-review.yml
BRANCH=chore/ai-review-panel

# Owner-qualified: the open-source Protocol Wealth repos are in their own org.
# Regenerate the rivendale half with:
#   gh repo list rivendale --limit 100 --no-archived \
#     --json name,isFork -q '.[] | select(.isFork | not) | .name'
REPOS=(
  rivendale/rygiel-family
  rivendale/rygiel-shared
  rivendale/pwgraph-core
  rivendale/hearforspeech
  rivendale/hearforspeech-server
  rivendale/iso-ai-game
  rivendale/m720q01-homelab
  rivendale/TerranovaPrep
  rivendale/series63-study-hub
  rivendale/series65-study-hub
  rivendale/iocalc-agent-env
  rivendale/rf-server
  # Open source, so in scope. The private PW repos are not.
  Protocol-Wealth/nexus-core
  Protocol-Wealth/pwcli-core
  Protocol-Wealth/pwos-core
  Protocol-Wealth/pwplan-core
  Protocol-Wealth/shard-core
  Protocol-Wealth/pw-learnai
)

read -r -d '' CALLER <<YAML || true
# Managed by $HOST. Edit the panel there, not here.
name: AI review

on:
  pull_request:
    # \`unlabeled\` too: removing a tier label emits that, not \`labeled\`, so
    # without it a stale deep-tier run keeps going and posts a result for a
    # tier the PR no longer asks for.
    types: [opened, synchronize, reopened, ready_for_review, labeled, unlabeled]

# Keyed to the PR, not the branch: a rapid second push or a label change would
# otherwise start an independent run, spend Actions minutes and model tokens on
# a commit that is already superseded, and race to post the comment. The panel's
# own concurrency group governs its jobs but cannot cancel this caller's run.
concurrency:
  group: ai-review-\${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  panel:
    # Required: a called workflow cannot request more permission than its
    # caller holds, and the default token is read-only.
    permissions:
      contents: read
      pull-requests: write
    uses: $HOST/.github/workflows/ai-review.yml@main
    secrets:
      OPENAI_API_KEY: \${{ secrets.OPENAI_API_KEY }}
YAML

# Reads the caller already in a repo, if any. Empty when there is none.
caller_of() {
  gh api "repos/$1/contents/$WORKFLOW" --jq '.content' 2>/dev/null \
    | tr -d '\n' | base64 -d 2>/dev/null || true
}

if [ "$APPLY" != "--apply" ]; then
  echo "DRY RUN. ${#REPOS[@]} repos:"
  for repo in "${REPOS[@]}"; do
    body=$(caller_of "$repo")
    if printf '%s' "$body" | grep -q "uses: $HOST"; then
      state="already on the public host"
    elif printf '%s' "$body" | grep -q 'uses: .*/\.github/workflows/ai-review\.yml'; then
      state="REPOINT -- calls $(printf '%s' "$body" | grep -oP 'uses: \K[^/]+/[^/]+' || true)"
    elif [ -n "$body" ]; then
      state="has an ai-review.yml that is not a caller; SKIPPED"
    else
      state="add"
    fi
    printf '  %-38s %s\n' "$repo" "$state"
  done
  echo
  echo "Re-run with --apply to open the PRs."
  [ -n "${OPENAI_API_KEY:-}" ] || echo "NOTE: OPENAI_API_KEY is not set; the secret step would be skipped."
  exit 0
fi

for repo in "${REPOS[@]}"; do
  echo "--- $repo"

  body=$(caller_of "$repo")
  if printf '%s' "$body" | grep -q "uses: $HOST"; then
    echo "    already on the public host, skipping"
  elif [ -n "$body" ] && ! printf '%s' "$body" | grep -q 'uses: .*/\.github/workflows/ai-review\.yml'; then
    # Something else owns this path -- the panel's own definition, most
    # likely. Overwriting it with a caller would delete the panel.
    echo "    ai-review.yml exists and is not a caller; NOT touching it"
  else
    # Not `grep -q ... && action=repoint`: under `set -e` a bare AND-list that
    # ends non-zero aborts the script, so a repo with no caller would kill the
    # whole rollout instead of getting one.
    action=add
    if printf '%s' "$body" | grep -q 'uses: '; then action=repoint; fi
    tmp=$(mktemp -d)
    gh repo clone "$repo" "$tmp/r" -- --depth 1 --quiet 2>/dev/null
    (
      cd "$tmp/r"
      default=$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name)
      git checkout -q -b "$BRANCH"
      mkdir -p .github/workflows
      printf '%s\n' "$CALLER" > "$WORKFLOW"
      git add "$WORKFLOW"
      if [ "$action" = repoint ]; then
        subject="ci: call the AI review panel from its public host"
        detail="A public repo cannot call a reusable workflow in a private one, so
the panel moved to the public $HOST. This repointing is the
whole change; the caller's contract is unchanged."
      else
        subject="ci: call the central AI review panel"
        detail="Adds the caller for $HOST's reusable review workflow.
Deliberately names no model: tiering (luna routine, terra for sensitive
paths, sol on the deep-review label) lives in the panel so it changes in
one place."
      fi
      git -c user.name="Nick Rygiel" -c user.email="nick.ryg@gmail.com" \
        commit -q -m "$subject

$detail

Requires the repo secret OPENAI_API_KEY."
      git push -q -u origin "$BRANCH"
      gh pr create --repo "$repo" --base "$default" --head "$BRANCH" \
        --title "$subject" \
        --body "Wires this repo into the reusable panel in \`$HOST\`. No model is named here; tiering lives in the panel. Needs the \`OPENAI_API_KEY\` repo secret."
    )
    rm -rf "$tmp"
    echo "    PR opened ($action)"
  fi

  if [ -n "${OPENAI_API_KEY:-}" ]; then
    gh secret set OPENAI_API_KEY --repo "$repo" --body "$OPENAI_API_KEY"
    echo "    secret set"
  else
    echo "    OPENAI_API_KEY not exported; secret NOT set"
  fi
done

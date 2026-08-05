#!/usr/bin/env bash
# Wires the central AI review panel into rivendale repos.
#
#   OPENAI_API_KEY=sk-... ./scripts/rollout-ai-review.sh          # dry run
#   OPENAI_API_KEY=sk-... ./scripts/rollout-ai-review.sh --apply
#
# Opens one PR per repo adding the caller workflow, and sets the per-repo
# secret. Per-repo because `rivendale` is a personal account, so there are no
# organisation-level Actions secrets.
#
# NOTE: a PUBLIC repo cannot call a reusable workflow hosted in a PRIVATE one.
# rygiel-shared is private, so the five public repos below fail at startup while
# the private ones work. Verified 2026-08-05: every private repo succeeded and
# every public one failed. Covering them needs the panel in a public repo.
#
# Excluded on purpose:
#   - the Protocol-Wealth org entirely; reviewed under a separate process
#   - forks (OpenBBTerminal, TinyTroupe, tank-royale); upstream code, not ours
#   - archived repos
#
# `pwgraph-core` IS in scope despite the prefix. It is the family brain behind
# brain.rygiel.family, lives in this personal account, and is personal/family
# only -- it is not a Protocol Wealth repo. Do not drop it for matching "pw".
set -euo pipefail

OWNER=rivendale
APPLY=${1:-}
WORKFLOW=.github/workflows/ai-review.yml
BRANCH=chore/ai-review-panel

# Own, active, non-fork repos. Regenerate with:
#   gh repo list rivendale --limit 100 --no-archived \
#     --json name,isFork -q '.[] | select(.isFork | not) | .name'
REPOS=(
  rygiel-family
  rygiel-shared
  pwgraph-core
  hearforspeech
  hearforspeech-server
  iso-ai-game
  m720q01-homelab
  TerranovaPrep
  series63-study-hub
  series65-study-hub
  iocalc-agent-env
  rf-server
)

read -r -d '' CALLER <<'YAML' || true
# Managed by rivendale/ci-workflows. Edit the panel there, not here.
name: AI review

on:
  pull_request:
    # `unlabeled` too: removing a tier label emits that, not `labeled`, so
    # without it a stale deep-tier run keeps going and posts a result for a
    # tier the PR no longer asks for.
    types: [opened, synchronize, reopened, ready_for_review, labeled, unlabeled]

# Keyed to the PR, not the branch: a rapid second push or a label change would
# otherwise start an independent run, spend Actions minutes and model tokens on
# a commit that is already superseded, and race to post the comment. The panel's
# own concurrency group governs its jobs but cannot cancel this caller's run.
concurrency:
  group: ai-review-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  panel:
    # Required: a called workflow cannot request more permission than its
    # caller holds, and the default token is read-only.
    permissions:
      contents: read
      pull-requests: write
    uses: rivendale/ci-workflows/.github/workflows/ai-review.yml@main
    secrets:
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
YAML

if [ "$APPLY" != "--apply" ]; then
  echo "DRY RUN. Would wire ${#REPOS[@]} repos:"
  printf '  %s\n' "${REPOS[@]}"
  echo
  echo "Re-run with --apply to open the PRs."
  [ -n "${OPENAI_API_KEY:-}" ] || echo "NOTE: OPENAI_API_KEY is not set; the secret step would be skipped."
  exit 0
fi

for repo in "${REPOS[@]}"; do
  echo "--- $repo"

  # Checks for a CALLER, not just the filename: rygiel-shared holds the panel
  # under the same path, so a name-only check skipped the very repo the panel
  # lives in and left its own PRs unreviewed.
  if gh api "repos/$OWNER/$repo/contents/$WORKFLOW" --jq '.content' 2>/dev/null \
       | tr -d '\n' | base64 -d 2>/dev/null | grep -q "uses: $OWNER/rygiel-shared"; then
    echo "    already wired, skipping"
  else
    tmp=$(mktemp -d)
    gh repo clone "$OWNER/$repo" "$tmp/r" -- --depth 1 --quiet 2>/dev/null
    (
      cd "$tmp/r"
      default=$(gh repo view "$OWNER/$repo" --json defaultBranchRef -q .defaultBranchRef.name)
      git checkout -q -b "$BRANCH"
      mkdir -p .github/workflows
      printf '%s\n' "$CALLER" > "$WORKFLOW"
      git add "$WORKFLOW"
      git -c user.name="Nick Rygiel" -c user.email="nick.ryg@gmail.com" \
        commit -q -m "ci: call the central AI review panel

Adds the caller for rivendale/ci-workflows's reusable review workflow.
Deliberately names no model: tiering (luna routine, terra for sensitive
paths, sol on the deep-review label) lives in the panel so it changes in
one place.

Requires the repo secret OPENAI_API_KEY."
      git push -q -u origin "$BRANCH"
      gh pr create --repo "$OWNER/$repo" --base "$default" --head "$BRANCH" \
        --title "ci: call the central AI review panel" \
        --body "Wires this repo into the reusable panel in \`rivendale/ci-workflows\`. No model is named here; tiering lives in the panel. Needs the \`OPENAI_API_KEY\` repo secret."
    )
    rm -rf "$tmp"
    echo "    PR opened"
  fi

  if [ -n "${OPENAI_API_KEY:-}" ]; then
    gh secret set OPENAI_API_KEY --repo "$OWNER/$repo" --body "$OPENAI_API_KEY"
    echo "    secret set"
  else
    echo "    OPENAI_API_KEY not exported; secret NOT set"
  fi
done

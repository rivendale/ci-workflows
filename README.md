# AI review panel

The one AI code review definition for rivendale repos. Callers name no model;
they declare what changed and this decides which tier reviews it.

One reusable workflow, called by every rivendale repo that wants AI review on
its pull requests. Centralised so the model tiering, the cost controls and the
comment behaviour are changed in one file rather than in a dozen copies.

Protocol Wealth repos are out of scope. They live under the `Protocol-Wealth`
org and are reviewed under a separate process.

`pwgraph-core` is in scope despite the prefix: it is the family brain behind
brain.rygiel.family, in this account, personal/family only. It is not a
Protocol Wealth repo and should not be dropped for matching "pw".

## Tiers

The caller does not pick a model. It says what changed and the panel decides:

| Tier | Model | Cost (in / out per MTok) | When |
| --- | --- | --- | --- |
| Routine | `gpt-5.6-luna` | $0.20 / $1.20 | The default |
| Sensitive | `gpt-5.6-terra` | $2.00 / $12.00 | Diff touches auth, secrets, SQL, CI, or dependency manifests |
| Deep | `gpt-5.6-sol` | $5.00 / $30.00 | PR carries the `deep-review` label |

Reasoning effort is set per tier too — `medium` for routine, `high` for the
other two. It has to be explicit: there is no `config.toml` on a runner, and the
CLI defaulted to effort `none`, which produces a confident-looking review from a
model that did not think about it. That is worse than no review, because it
reads as a clean one.

Prices checked against <https://developers.openai.com/api/docs/pricing> on
2026-08-05. Luna is a chat/reasoning model; it does not serve embeddings,
transcription, moderation or image generation, so nothing of that sort should be
pointed at it.

Sensitive paths and the escalation label are inputs, so a repo with a different
shape can override them without forking the workflow.

## Adding a repo

Copy `ai-review-caller.template.yml` into the repo as
`.github/workflows/ai-review.yml`, or run `scripts/rollout-ai-review.sh` from
this repo to open the PRs in bulk.

## Two things the caller must do

Grant the permissions. A called workflow cannot request more than its caller
holds, and the default token is read-only, so a caller that omits

```yaml
    permissions:
      contents: read
      pull-requests: write
```

fails at startup — with no message in the run log, which is why this is written
down. Job-level `timeout-minutes` also does not accept an expression, and
hyphenated input names parse as subtraction (`inputs.timeout-minutes` reads as
`inputs.timeout` minus `minutes`), so inputs here use underscores.

## Why this repo is public

A public repository cannot call a reusable workflow that lives in a private one.
The panel started life in the private `rygiel-shared`, and the split was exact —
verified across ten repos on 2026-08-05: every private caller worked and every
public one failed at startup.

So the panel lives here, public, and any repo can call it regardless of its own
visibility. Nothing here is sensitive; it is CI logic. The key stays a per-repo
secret and never appears in this repo.

## Sandbox

The reviewer runs with its own sandbox disabled. Bubblewrap cannot configure a
network namespace inside a GitHub runner, and every git command the reviewer
tried failed with `bwrap: loopback: Failed RTM_NEWADDR`. The runner is already
the isolation boundary: ephemeral, per job, holding a read-scoped token and the
review key and nothing else.

The residual risk is a prompt injection in a trusted-branch PR getting the
reviewer to run something on the runner. Fork pull requests do not receive
secrets, so an outside contributor cannot reach the key, and the job holds only
`contents: read` and `pull-requests: write`.

## The one prerequisite

Each repo needs an `OPENAI_API_KEY` secret.

`rivendale` is a personal account rather than an organisation, so there are no
org-level Actions secrets: the key has to be set per repo. `scripts/rollout-ai-review.sh`
does that for you if `OPENAI_API_KEY` is exported when you run it.

The Codex CLI's interactive session auth (`~/.codex/auth.json`) does **not**
work in Actions. It needs a real API key.

## Cost shape

These repos are private, so Actions minutes bill. The panel is deliberately
lean: pull requests only, drafts skipped, `cancel-in-progress` so a force-push
does not pay for two reviews, and a hard timeout because a hung review still
bills.

The review never fails the build. It reports, and a person decides; a reviewer
outage must not block a merge.

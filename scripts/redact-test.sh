#!/usr/bin/env bash
# Exercises the panel's redact() against fixtures. Like detector-test.sh, the
# function is lifted verbatim out of the Review step, so a change there that
# this file does not also see is a change that was never tested.
#
# No fixture below is a real credential. Each token-shaped value is assembled
# at run time from a prefix and filler, so this file holds nothing a secret
# scanner should flag, and nothing that would work anywhere.
set -uo pipefail

WF=${1:-"$(dirname "$0")/../.github/workflows/ai-review.yml"}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

extract() { # workflow -> $WORK/redact.sh
  sed -n '/^          redact() {/,/^          }$/p' "$1" | sed 's/^          //' > "$WORK/redact.sh"
}
extract "$WF"
[ -s "$WORK/redact.sh" ] || { echo "FAIL: could not extract redact()"; exit 1; }

fill() { printf "%${2}s" '' | tr ' ' "$1"; }  # fill CHAR COUNT
KEY="plain$(fill q 24)"                        # the step's own key, no known shape

pass=0; fail=0
run() { # text -> redacted text on stdout
  printf '%s' "$1" > "$WORK/in"
  # shellcheck disable=SC1091
  ( export OPENAI_API_KEY="$KEY"; . "$WORK/redact.sh"; redact "$WORK/in" "$WORK/out" > /dev/null ) \
    && cat "$WORK/out"
}
gone() { # name text secret: the secret must not survive
  local out; out=$(run "$2")
  if [[ "$out" == *"$3"* || "$out" != *"[REDACTED]"* ]]; then
    fail=$((fail + 1)); printf '  NOT OK %s -- survived: %s\n' "$1" "$out"
  else
    pass=$((pass + 1)); printf '  ok    %s\n' "$1"
  fi
}
kept() { # name text: ordinary review text must come through unchanged
  local out; out=$(run "$2")
  if [ "$out" != "$2" ]; then
    fail=$((fail + 1)); printf '  NOT OK %s -- changed to: %s\n' "$1" "$out"
  else
    pass=$((pass + 1)); printf '  ok    %s\n' "$1"
  fi
}

SK="sk-proj-$(fill A 40)"
GHP="ghp_$(fill B 36)"
PAT="github_pat_$(fill C 60)"
AWS="AKIA$(fill D 16)"
SLACK="xoxb-$(fill 1 12)-$(fill 2 12)"
JWT="eyJ$(fill e 20).eyJ$(fill f 20).$(fill g 20)"
OPAQUE="$(fill z 32)"
PEM_BODY="$(fill M 64)"

echo "Secrets that must be removed:"
gone "the step's own key, verbatim"   "env printed OPENAI_API_KEY $KEY here"  "$KEY"
gone "OpenAI-style key"               "found $SK in config"                   "$SK"
gone "GitHub classic token"           "token: $GHP"                           "$GHP"
gone "GitHub fine-grained token"      "using $PAT"                            "$PAT"
gone "AWS access key id"              "aws $AWS"                              "$AWS"
gone "Slack token"                    "slack $SLACK"                          "$SLACK"
gone "JWT"                            "cookie $JWT"                           "$JWT"
gone "private key block"              "$(printf -- '-----BEGIN RSA PRIVATE KEY-----\n%s\n-----END RSA PRIVATE KEY-----' "$PEM_BODY")" "$PEM_BODY"
gone "Authorization header"           "Authorization: Bearer $OPAQUE"         "$OPAQUE"
gone "auth.json field"                "{\"OPENAI_API_KEY\": \"$OPAQUE\"}"     "$OPAQUE"
gone "env dump line"                  "$(printf 'PATH=/usr/bin\nSERVICE_TOKEN=%s\n' "$OPAQUE")" "$OPAQUE"

echo
echo "Ordinary review text that must survive unchanged:"
kept "a P1 finding about tokens"      "- [P1] Compare tokens with strict equality; loose equality accepts coerced values."
kept "code that names a token"        "const token = getToken(); if (!password) return;"
kept "a short sk- identifier"         "the sk-1 variant is fine"
kept "a SHA and a URL"                "pinned to 3d3c42e5aac5ba805825da76410c181273ba90b1 at https://github.com/rivendale/ci-workflows"

echo
echo "Mutations (each MUST break at least one fixture):"
mutate() { # name sed-expression
  local name=$1 expr=$2 saved=$fail saved_pass=$pass
  sed "$expr" "$WF" > "$WORK/mutant.yml"
  if cmp -s "$WORK/mutant.yml" "$WF"; then
    echo "  NOT OK $name -- mutation did not change the file"; fail=$((fail + 1)); return
  fi
  extract "$WORK/mutant.yml"
  local before=$fail
  { gone k "x $KEY" "$KEY"; gone s "x $SK" "$SK"; gone a "Authorization: Bearer $OPAQUE" "$OPAQUE"
    gone j "{\"api_key\": \"$OPAQUE\"}" "$OPAQUE"; } > /dev/null
  local broke=$((fail - before)); fail=$saved; pass=$saved_pass
  if [ "$broke" -gt 0 ]; then
    pass=$((pass + 1)); printf '  ok    %s -- caught (%s fixture(s) broke)\n' "$name" "$broke"
  else
    fail=$((fail + 1)); printf '  NOT OK %s -- SURVIVED; the fixtures do not test this\n' "$name"
  fi
}
# These are sed scripts, not shell expansions.
# shellcheck disable=SC2016
mutate "skip the step's own secrets"  's/if len(value) >= 8 and value in text:/if False:/'
mutate "drop the sk- pattern"         '/sk-\[A-Za-z0-9_-\]/d'
mutate "drop the labelled values"     's/text, k = re.subn(pattern, r.\\1\[REDACTED\]., text)/k = 0/'
extract "$WF"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

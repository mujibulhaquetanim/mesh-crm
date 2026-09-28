#!/usr/bin/env bash
#
# Build the production inbox image as the COMMUNITY EDITION: the MIT core plus
# this fork's custom/ layer, with no enterprise/ code in it.
#
#   Usage: scripts/build-ce-image.sh <git-sha>        (a commit on origin/develop)
#   Prints the image tag on success: mesh-crm:<sha>
#
# Why (docs/fork/MIT_ONLY.md): enterprise/ is licensed for production only with a
# paid Chatwoot Enterprise licence, and while it is loaded its nightly
# ReconcilePlanConfigService resets the Zasmate branding rows to Chatwoot's.
# DISABLE_ENTERPRISE=true does not help on this fork: with custom/ present,
# ChatwootApp.extensions always includes enterprise, so every Enterprise:: overlay
# still loads. The folder has to be absent from the image. This is the same step
# upstream's own CE image uses (.github/workflows/publish_foss_docker.yml).
#
# Steps, each one stopping the script on failure:
#   0. the owner's rebuild rule (docs/fork/README.md ground rule 9): <sha> must
#      carry upstream/develop's latest, and every paid feature upstream moved
#      into the MIT core since the last review must have been made available
#      (scripts/fork-policy/core-moves.py, UPSTREAM_SYNC.md §5c)
#   1. fresh clone at <sha> (never the working checkout: untracked folders would
#      land in the image)
#   2. fork policy check on the clone (brand + vendor feature policy)
#   3. strip enterprise/ and spec/enterprise/, label the edition "ce"
#   4. docker build (log to a file; never pipe a build to tail)
#   5. verify the image: no /app/enterprise, the right .git_sha, the app boots its
#      Ruby native deps
#
# READ THE LAST LINE. Only "CE IMAGE OK" means the image may be pushed.

set -euo pipefail

SHA="${1:?usage: scripts/build-ce-image.sh <git-sha>}"
REPO="$(git rev-parse --show-toplevel)"
WORK="${BUILD_DIR:-/tmp/mesh-crm-build}"
LOG="${WORK}.log"
TAG="mesh-crm:${SHA}"

echo "0/5 synced with upstream, and nothing freed by upstream left switched off"
git -C "$REPO" fetch -q upstream develop
python3 "$REPO/scripts/fork-policy/core-moves.py" --ref "$SHA" --require-synced

echo "1/5 fresh clone at ${SHA} → ${WORK}"
rm -rf "$WORK"
git clone -q --no-local "$REPO" "$WORK"
git -C "$WORK" checkout -q "$SHA"

echo "2/5 fork policy check"
python3 "$WORK/scripts/fork-policy/check.py" --tree "$WORK"

echo "3/5 strip enterprise/ (community edition)"
rm -rf "$WORK/enterprise" "$WORK/spec/enterprise"
printf '\nENV CW_EDITION="ce"\n' >> "$WORK/docker/Dockerfile"
test ! -e "$WORK/enterprise" || { echo "enterprise/ still present" >&2; exit 1; }

echo "4/5 docker build (log: ${LOG})"
if ! docker build --progress=plain -f "$WORK/docker/Dockerfile" -t "$TAG" "$WORK" >"$LOG" 2>&1; then
  echo "BUILD FAILED — read ${LOG}" >&2
  exit 1
fi

echo "5/5 verify the image"
docker run --rm --entrypoint sh "$TAG" -c '
  set -e
  if [ -e /app/enterprise ]; then echo "FAIL: /app/enterprise is in the image"; exit 1; fi
  echo "no enterprise/: ok"
  echo "git sha: $(cat /app/.git_sha)"
  echo "edition: ${CW_EDITION:-unset}"
'
docker run --rm -e RAILS_ENV=production --entrypoint sh "$TAG" -c \
  'cd /app && bundle check >/dev/null && bundle exec ruby -e "require \"pg\"; require \"nokogiri\"; puts :native_ok"'

echo "CE IMAGE OK: ${TAG}"

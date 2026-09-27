#!/usr/bin/env bash
#
# Install the fork policy check as this clone's git pre-push hook.
#
#   Usage: scripts/fork-policy/install-pre-push-hook.sh
#
# Once per clone: git does not version hooks. After it, every `git push` runs
# `scripts/fork-policy/check.py` on the checkout and refuses the push on a FAIL.
# `git push --no-verify` skips it; don't, unless the check itself is what you
# are fixing.
#
# Upstream's `.husky/` hooks are not active in this fork (husky is never
# installed, `core.hooksPath` is unset), so the hook goes in `.git/hooks/`,
# a fork-only location that no upstream merge can touch.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOKS_PATH="$(git -C "$ROOT" config --get core.hooksPath || true)"
if [ -n "$HOOKS_PATH" ]; then
  echo "core.hooksPath is set to '$HOOKS_PATH', so git ignores .git/hooks." >&2
  echo "Add this line to that directory's pre-push instead:" >&2
  echo "  python3 scripts/fork-policy/check.py || exit 1" >&2
  exit 1
fi

HOOK="$(git -C "$ROOT" rev-parse --git-path hooks)/pre-push"
MARKER='# fork-policy-check'

if [ -e "$HOOK" ] && ! grep -q "$MARKER" "$HOOK"; then
  echo "$HOOK already exists and is not ours; not overwriting it." >&2
  echo "Add this line to it instead:  python3 scripts/fork-policy/check.py || exit 1" >&2
  exit 1
fi

cat > "$HOOK" <<'EOF'
#!/bin/sh
# fork-policy-check — installed by scripts/fork-policy/install-pre-push-hook.sh
# Refuses a push that breaks the brand or the vendor feature policy.
# See docs/fork/VENDOR_FEATURE_POLICY.md.
root="$(git rev-parse --show-toplevel)"
python3 "$root/scripts/fork-policy/check.py" --tree "$root" || {
  echo "push refused by the fork policy check (see FAIL lines above)" >&2
  exit 1
}
EOF
chmod +x "$HOOK"
echo "installed: $HOOK"

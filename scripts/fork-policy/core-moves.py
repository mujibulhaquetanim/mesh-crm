#!/usr/bin/env python3
"""Paid features upstream moved into the MIT core: find them, so we switch them on.

The owner's rule (2026-09-28, docs/fork/README.md ground rule 9): before every
rebuild, sync with upstream Chatwoot, and when a feature that used to be
enterprise-only is now in the community core, make it available. Production
ships the MIT core only (MIT_ONLY.md), so a feature upstream frees is ours to
use the day the sync lands, but nothing turns it on by itself. Companies moved
on 2026-09-24 and stayed off for every account (UPSTREAM_SYNC.md §3h).

    python3 scripts/fork-policy/core-moves.py                 # review: moves since the marker
    python3 scripts/fork-policy/core-moves.py --since <sha>   # audit any range
    python3 scripts/fork-policy/core-moves.py --ref <sha> --require-synced   # the build gate
    python3 scripts/fork-policy/core-moves.py --mark          # after acting: record the review

A move is either signal, between the reviewed upstream commit (the marker file)
and the upstream commit merged into <ref>:
  flag   a config/features.yml entry that lost `premium: true`;
  code   files git sees RENAMED out of enterprise/ into the core.
Then UPSTREAM_SYNC.md §5c says what "make it available" means.

--require-synced also fails when <ref> does not contain upstream/develop: the
build must carry upstream's latest. Set ALLOW_UNSYNCED_BUILD="<reason>" only for
an emergency rebuild, and say so in the release notes.

Exit 1 on unreviewed moves or an unsynced ref. READ THE RESULT LINE.
"""
import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MARKER = 'scripts/fork-policy/core-moves.reviewed'


def git(*args, check=True):
    out = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True)
    if check and out.returncode != 0:
        sys.exit(f'git {" ".join(args)} failed: {out.stderr.strip()}')
    return out


def premium_flags(commit):
    text = git('show', f'{commit}:config/features.yml').stdout
    flags = {}
    for block in re.split(r'\n(?=- name: )', text):
        name = re.search(r'^- name: (\S+)', block, re.M)
        if name:
            flags[name.group(1)] = bool(re.search(r'^\s*premium: true\s*$', block, re.M))
    return flags


def moved_code(since, until):
    """Files renamed out of enterprise/ into the core, grouped by the model they move with."""
    diff = git('diff', '-M', '--name-status', '--diff-filter=R', since, until).stdout
    paths = [new for _, old, new in (line.split('\t') for line in diff.splitlines())
             if old.startswith('enterprise/') and not new.startswith('enterprise/')]
    # "company" also matches companies/, _company, company_backfill_job …
    models = sorted({Path(p).stem for p in paths if p.startswith('app/models/') and '/concerns/' not in p},
                    key=len, reverse=True)
    moves = defaultdict(list)
    for path in paths:
        owner = next((m for m in models if m.rstrip('y') in path), 'no moved model')
        moves[owner].append(path)
    return moves


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ref', default='HEAD', help='the fork commit being reviewed or built')
    ap.add_argument('--since', help='upstream commit to compare from (default: the marker in --ref)')
    ap.add_argument('--require-synced', action='store_true', help='fail unless --ref contains upstream/develop')
    ap.add_argument('--mark', action='store_true', help='write the upstream commit in --ref to the marker file')
    args = ap.parse_args()

    if git('rev-parse', '--verify', '-q', 'upstream/develop', check=False).returncode != 0:
        sys.exit('no upstream/develop: git remote add upstream https://github.com/chatwoot/chatwoot.git '
                 '&& git fetch upstream develop')
    target = git('merge-base', args.ref, 'upstream/develop').stdout.strip()
    fails = []

    print(f'core-moves — {args.ref} carries upstream {target[:10]}\n')

    if args.require_synced:
        behind = int(git('rev-list', '--count', f'{target}..upstream/develop').stdout)
        if behind:
            reason = os.environ.get('ALLOW_UNSYNCED_BUILD', '').strip()
            msg = f'{args.ref} is {behind} upstream commit(s) behind upstream/develop: sync first (UPSTREAM_SYNC.md §6)'
            if reason:
                print(f'  warn  {msg} — OVERRIDDEN: {reason}')
            else:
                fails.append(msg)
        else:
            print('  ok    synced with upstream/develop')

    since = args.since or git('show', f'{args.ref}:{MARKER}').stdout.split()[0]
    before, after = premium_flags(since), premium_flags(target)
    freed = sorted(n for n, was in before.items() if was and after.get(n) is False)
    code = moved_code(since, target)

    for name in freed:
        print(f'  MOVE  flag {name}: no longer premium')
    for feature, paths in sorted(code.items()):
        print(f'  MOVE  code {feature}: {len(paths)} file(s) out of enterprise/, e.g. {paths[0]}')
    if not freed and not code:
        print(f'  ok    nothing moved from enterprise/ into core since {since[:10]}')

    reviewed = since == target or not (freed or code)
    if args.mark:
        (ROOT / MARKER).write_text(f'{target}\n')
        print(f'\n  marked upstream {target[:10]} as reviewed in {MARKER} — commit it with the change that acts on it')
    elif not reviewed:
        fails.append('unreviewed moves above: make each one available (UPSTREAM_SYNC.md §5c), '
                     'then run with --mark and commit the marker')

    print()
    for f in fails:
        print('  FAIL ', f)
    print('RESULT:', 'NOT SAFE TO BUILD' if fails else 'ok to build')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())

#!/bin/sh
# R1 (G82 stage 4, Run 19): rename the NebulaScreen repository, once, by Tim.
#
#   GitHub  coreflake1/NebulaOS-guppyscreen -> coreflake1/NebulaOS-nebulascreen
#   local   <workspace>/NebulaOS-guppyscreen -> <workspace>/NebulaOS-nebulascreen
#
# Idempotent: every step checks first and skips what is already done, so it
# can be run again after an interruption. Never recreates the old name on
# GitHub (old URLs keep working through GitHub's redirect, so old builds stay
# reproducible). Ends with RENAME_RESULT=PASS or RENAME_RESULT=FAIL.
#
#   sh /home/tim/workspace/NebulaOS/NebulaOS-firmware/tools/r1-rename-screen-repo.sh
set -u
WS=$(cd "$(dirname "$0")/../.." && pwd)
OWNER=coreflake1
OLD=NebulaOS-guppyscreen
NEW=NebulaOS-nebulascreen
fail() { echo "FAIL: $*"; echo "RENAME_RESULT=FAIL"; exit 1; }
ok() { echo "OK:   $*"; }

command -v gh >/dev/null 2>&1 || fail "gh (GitHub CLI) is not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in - run: gh auth login"

# 1. local preconditions (only while the old folder still exists)
if [ -d "$WS/$OLD/.git" ]; then
	[ -z "$(git -C "$WS/$OLD" status --porcelain)" ] || fail "$WS/$OLD has uncommitted changes"
	git -C "$WS/$OLD" fetch -q origin 2>/dev/null || true
	[ "$(git -C "$WS/$OLD" rev-parse HEAD)" = "$(git -C "$WS/$OLD" rev-parse origin/main 2>/dev/null)" ] \
		|| fail "$WS/$OLD main is not equal to origin/main - push or pull first"
fi

# 2. GitHub
if [ "$(gh repo view "$OWNER/$NEW" --json name -q .name 2>/dev/null)" = "$NEW" ]; then
	ok "GitHub already has $OWNER/$NEW"
else
	gh repo rename "$NEW" -R "$OWNER/$OLD" --yes || fail "gh repo rename failed"
	ok "GitHub renamed $OWNER/$OLD -> $OWNER/$NEW"
fi

# 3. the old Run 4 worktree (its commit is on origin/main) - removed, not moved
if [ -d "$WS/$OLD/.git" ] && git -C "$WS/$OLD" worktree list | grep -q "_worktrees/run4-ui-gs"; then
	git -C "$WS/$OLD" worktree remove --force "$WS/_worktrees/run4-ui-gs" || fail "could not remove _worktrees/run4-ui-gs"
	ok "removed the old worktree _worktrees/run4-ui-gs"
fi

# 4. local folder
if [ -d "$WS/$NEW/.git" ] && [ ! -e "$WS/$OLD" ]; then
	ok "local folder is already $NEW"
elif [ -d "$WS/$OLD/.git" ] && [ ! -e "$WS/$NEW" ]; then
	mv "$WS/$OLD" "$WS/$NEW" || fail "could not move $OLD to $NEW"
	ok "local folder moved to $WS/$NEW"
else
	fail "unexpected local state: check $WS/$OLD and $WS/$NEW by hand"
fi
git -C "$WS/$NEW" worktree prune
git -C "$WS/$NEW" worktree repair >/dev/null 2>&1 || true

# 5. remote URL
git -C "$WS/$NEW" remote set-url origin "https://github.com/$OWNER/$NEW.git"
ok "origin = https://github.com/$OWNER/$NEW.git"

# 6. verify
git -C "$WS/$NEW" ls-remote origin HEAD >/dev/null 2>&1 || fail "the new remote does not answer"
ok "new remote answers"
git ls-remote "https://github.com/$OWNER/$OLD.git" HEAD >/dev/null 2>&1 \
	&& ok "old URL still redirects (old builds stay reproducible)" \
	|| echo "WARN: the old URL does not redirect (check GitHub)"
[ "$(git -C "$WS/$NEW" rev-parse HEAD)" = "$(git -C "$WS/$NEW" rev-parse origin/main)" ] || fail "HEAD differs from origin/main after the rename"
if [ -x "$WS/tools/verify-workspace-identity.sh" ]; then
	"$WS/tools/verify-workspace-identity.sh" 2>/dev/null | grep -E "^DEV_IDENTITY_VALID=" || true
fi
echo "RENAME_RESULT=PASS"

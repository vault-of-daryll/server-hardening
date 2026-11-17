#!/usr/bin/env bash
# All staging and commits happen in a disposable clone, including uncommitted hook changes.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Avoid inherited repository paths when called from a hook or another test.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
git clone --quiet --no-hardlinks "$kit" "$work/repo"
cd "$work/repo"
cp "$kit/.githooks/pre-commit" "$kit/.githooks/commit-msg" "$kit/.githooks/pre-merge-commit" "$kit/.githooks/pre-push" .githooks/
cp "$kit/.gitignore" .gitignore
cp "$kit/README.md" README.md
mkdir -p "$work/bin"
if ! command -v gitleaks >/dev/null 2>&1; then
  echo 'SKIP gitleaks is not installed: its cases are skipped and a stub stands in'
  printf '#!/bin/sh\nexit 0\n' > "$work/bin/gitleaks"
  chmod +x "$work/bin/gitleaks"
  export PATH="$work/bin:$PATH"
fi
git config user.name 'Hook Test'
git config user.email 'hooks@example.test'
git config core.hooksPath .githooks
printf '# synthetic test pattern\n\n203\\.0\\.113\\.99\n' > .git/info/private-patterns
# Prepare the clone with the current hooks and allowlist.
git add .githooks .gitignore README.md
if ! git diff --cached --quiet; then
  git commit -qm 'Prepare hook regression fixture'
fi
base=$(git rev-parse HEAD)
reject() {
  local label=$1 diagnostic=$2
  shift 2
  if "$@" > "$work/output" 2>&1; then
    echo "FAIL $label: hook accepted the change"; exit 1
  fi
  if grep -F -e '203.0.113.99' -e '203\.0\.113\.99' -e 'hooktest-private-name' "$work/output" >/dev/null; then
    echo "FAIL $label: hook exposed private data"; exit 1
  fi
  if ! grep -Fq -- "$diagnostic" "$work/output"; then
    echo "FAIL $label: expected diagnostic missing"; exit 1
  fi
  echo "PASS $label"
}
reset_case() { git reset --hard -q HEAD; git clean -fdqx; }
printf '\n203.0.113.99\n' >> README.md
git add README.md
reject 'plain added line' 'private pattern #3 matched in README.md' git commit -qm 'Test content'
reset_case
printf '\n++203.0.113.99\n' >> README.md
git add README.md
reject 'line starting with ++' 'private pattern #3 matched in README.md' git commit -qm 'Test content'
reset_case
# Allow these paths so private-name checking, rather than the allowlist, must reject them.
printf '\n!/203*\n' >> .gitignore
printf 'clean\n' > 203.0.113.99
git add .gitignore 203.0.113.99
reject 'pattern in added file name' 'private pattern #3 matched in <staged path>' git commit -qm 'Test name'
reset_case
git mv README.md excluded.txt
reject 'rename onto ignored path' 'Staged path is excluded by the .gitignore allowlist' git commit -qm 'Test rename'
reset_case
printf '\n!/203*\n' >> .gitignore
git mv README.md 203.0.113.99
git add .gitignore
reject 'rename onto pattern name' 'private pattern #3 matched in <staged path>' git commit -qm 'Test rename'
reset_case
reject 'private commit message' 'private pattern #3 matched in <commit message>' git commit --allow-empty -qm 'Test 203.0.113.99'
reset_case
printf 'hooktest-private-name\n' >> .git/info/private-patterns
printf '\n!/hooktest-*\n' >> .gitignore
printf '203.0.113.99\n' > hooktest-private-name
git add .gitignore hooktest-private-name
reject 'earlier content pattern and later name pattern' 'private pattern #4 matched in <staged path>' git commit -qm 'Test both patterns'
reset_case
# A different file must not disclose a protected name before all paths are checked.
printf '\n203.0.113.99\n' >> README.md
printf 'clean\n' > hooktest-private-name
git add README.md
git add -f hooktest-private-name
reject 'all names checked before any contents' 'private pattern #4 matched in <staged path>' .githooks/pre-commit
reset_case
printf 'clean\n' > excluded.txt
git add -f excluded.txt
printf '\n!/excluded.txt\n' >> .gitignore
reject 'unstaged allowlist edit' 'stage or discard your .gitignore edit first' git commit -qm 'Test unstaged allowlist'
reset_case
printf '\n!/1:*\n' >> .gitignore
printf '203.0.113.99\n' > 1:notes
git add .gitignore 1:notes
reject 'colon in staged path' 'private pattern #3 matched in 1:notes' git commit -qm 'Test colon path'
printf 'clean\n' > 1:notes
git add 1:notes
git commit -qm 'Allow clean colon path' > "$work/output" 2>&1
echo 'PASS clean colon path'
# Seed a tracked private name with no private patterns, then prove its deletion is allowed.
: > .git/info/private-patterns
printf '\n!/203*\n' >> .gitignore
printf 'clean\n' > 203.0.113.99
git add .gitignore 203.0.113.99
git commit -qm 'Prepare deletion fixture' > "$work/output" 2>&1
printf '# synthetic test pattern\n\n203\\.0\\.113\\.99\nhooktest-private-name\n' > .git/info/private-patterns
git rm -q 203.0.113.99
git commit -qm 'Delete private path' > "$work/output" 2>&1
echo 'PASS deletion of private path'
printf 'Clean subject\n# Please enter the commit message for your changes. Lines starting\n# with \047#\047 will be ignored, and an empty message aborts the commit.\n' > "$work/message"
.githooks/commit-msg "$work/message"
echo 'PASS clean message with Git template'
printf 'Clean subject\n# 203.0.113.99\n# with \047#\047 will be ignored, and an empty message aborts the commit.\n' > "$work/message"
reject 'private value on a comment line' 'private pattern #3 matched in <commit message>' .githooks/commit-msg "$work/message"
printf 'Clean subject\n#12 moved to 203.0.113.99\n' > "$work/message"
reject 'hash line kept by commit -m' 'private pattern #3 matched in <commit message>' .githooks/commit-msg "$work/message"
mkdir -p tests && printf '!secret.txt\n' > tests/.gitignore && printf 'clean\n' > tests/secret.txt
git add tests/secret.txt
reject 'nested .gitignore re-including a file' 'only the root .gitignore is allowed' .githooks/pre-commit
git rm -q --cached tests/secret.txt && rm tests/.gitignore tests/secret.txt
mkdir -p .venv && printf '*\n' > .venv/.gitignore
printf '\nClean venv case\n' >> README.md && git add README.md
.githooks/pre-commit > "$work/output" 2>&1
echo 'PASS .gitignore inside an ignored folder'
git reset -q && git checkout -q -- README.md && rm -rf .venv
printf '\n!/shot.png\n' >> .gitignore && printf '\211PNG\r\n\032\n\000\000' > shot.png
git add .gitignore shot.png
reject 'screenshot or other binary file' 'binary files (screenshots, images, archives) are not allowed' .githooks/pre-commit
reset_case
printf '\n203.0.113.99\n' >> README.md
git add README.md
reject 'merge hook runs staged checks' 'private pattern #3 matched in README.md' .githooks/pre-merge-commit
reset_case
printf '[\n' > .git/info/private-patterns
printf '\nClean change\n' >> README.md
git add README.md
reject 'invalid content pattern' 'private pattern #1 is not a valid regular expression' .githooks/pre-commit
reject 'invalid message pattern' 'private pattern #1 is not a valid regular expression' .githooks/commit-msg README.md
printf '# synthetic test pattern\n\n203\\.0\\.113\\.99\n' > .git/info/private-patterns
git commit -qm 'Clean regression commit' > "$work/output" 2>&1
echo 'PASS clean commit'
# Push cases start again from the prepared commit; earlier fixtures hold the test value on purpose.
git checkout -q -B push-cases "$base"
git init -q --bare "$work/remote.git" && git remote add test "$work/remote.git"
# A shallow checkout (CI's default) makes this clone shallow too.
git -C "$work/remote.git" config receive.shallowUpdate true
# Seed the remote without the hook: this script's own history holds the test value on purpose.
git push -q --no-verify test HEAD:refs/heads/main
git commit -q --allow-empty -m 'Clean push'
git push -q test HEAD:refs/heads/main > "$work/output" 2>&1 || { cat "$work/output"; exit 1; }
echo 'PASS clean push'
printf '\n203.0.113.99\n' >> README.md
git add README.md && git commit -q --no-verify -m 'Skipped hooks'
reject 'push of a commit made with --no-verify' 'matched in outgoing commit' git push -q test HEAD:refs/heads/main
git reset -q --hard HEAD~1
git commit -q --no-verify --allow-empty -m 'Clean subject' --author='203.0.113.99 <a@example.test>'
reject 'push of a commit with a private author' 'matched in outgoing commit' git push -q test HEAD:refs/heads/main
git reset -q --hard HEAD~1
# The remote moved and this clone never fetched it: its tip is unknown here.
printf '\n203.0.113.99\n' >> README.md
git add README.md && git commit -q --no-verify -m 'Skipped hooks'
reject 'push over an unknown remote tip' 'matched in outgoing commit' \
  sh -c 'printf "refs/heads/main %s refs/heads/main %s\n" "$(git rev-parse HEAD)" 1111111111111111111111111111111111111111 | .githooks/pre-push test "$1"' _ "$work/remote.git"
git reset -q --hard HEAD~1
git tag -a -m 'Release 203.0.113.99' v9.9.9
reject 'push of a tag message on a pushed commit' 'matched in an outgoing tag message' git push -q test v9.9.9
git tag -d v9.9.9 >/dev/null
git tag -a -m 'Release 203.0.113.99' inner && git tag -a -m 'Release' v9.9.7 inner && git tag -d inner >/dev/null
reject 'push of a tag whose inner tag has a private message' 'matched in an outgoing tag message' git push -q test v9.9.7
git tag -d v9.9.7 >/dev/null
reject 'push to a branch named after a private value' 'matched in an outgoing branch or tag name' git push -q test HEAD:refs/heads/203.0.113.99
git checkout -q -b side && git commit -q --allow-empty -m 'Side' && git checkout -q push-cases
git merge -q --no-ff --no-commit side && printf '\n203.0.113.99\n' >> README.md && git add README.md
git commit -q --no-verify -m 'Merge side'
reject 'push of a change made inside a merge' 'matched in outgoing commit' git push -q test HEAD:refs/heads/main
git reset -q --hard HEAD~1
if [ -x "$work/bin/gitleaks" ]; then
  echo 'SKIP push of a secret added inside a merge (needs gitleaks)'
else
  # A token added while resolving a merge must reach gitleaks too; it is generated so no file holds one.
  token="ghp_$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 36)"
  git merge -q --no-ff --no-commit side && printf '\ntoken = %s\n' "$token" >> README.md && git add README.md
  git commit -q --no-verify -m 'Merge side'
  reject 'push of a secret added inside a merge' 'gitleaks found a secret' git push -q test HEAD:refs/heads/main
  git reset -q --hard HEAD~1
fi
blob=$(printf '203.0.113.99\n' | git hash-object -w --stdin)
git tag -a -m 'Release' v9.9.8 "$blob"
reject 'push of a tag that points at a file' 'only commits and tags of commits' git push -q test v9.9.8
git tag -d v9.9.8 >/dev/null
# Commits another remote already has must still be checked when pushed as a new ref.
printf '\n203.0.113.99\n' >> README.md
git add README.md && git commit -q --no-verify -m 'Skipped hooks'
git update-ref refs/remotes/private/main HEAD
reject 'push of commits only another remote has' 'matched in outgoing commit' git push -q test HEAD:refs/heads/fresh
git init -q --bare "$work/path.git"
reject 'push to a path of commits a remote already has' 'matched in outgoing commit' git push -q "$work/path.git" HEAD:refs/heads/main
git update-ref -d refs/remotes/private/main
git reset -q --hard HEAD~1
# A clean new ref pushed to a path with a space.
git init -q --bare "$work/sp ace.git"
# A path push checks the whole history, and this script's own history holds the test value, so push a fresh root commit.
clean=$(git commit-tree -m Clean "$(git mktree </dev/null)")
git push -q "$work/sp ace.git" "$clean:refs/heads/main" > "$work/output" 2>&1 || { cat "$work/output"; exit 1; }
echo 'PASS clean push to a path with a space'
git reset -q --hard "$base" && git branch -q -D side
echo 'ALL HOOK TESTS PASSED'

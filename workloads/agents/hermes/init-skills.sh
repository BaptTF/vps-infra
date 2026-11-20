#!/bin/sh
# Shared init for hermes-leo / hermes-lea (alpine/git). Léa runs it as root,
# Léo as APP_UID (10000, no capabilities): every step must tolerate files on
# the PVC that the current uid does not own.
# - copies the rendered config.yaml onto the PVC
# - syncs /opt/data/skills from the private agents-skills repo (deploy key)
#
# Policy: the repo is the source of truth, but local skill edits made by the
# agent are never overwritten. An upstream change that would clobber a local
# edit is skipped (logged) and the pod starts with what is on disk.
# A failed sync never blocks the pod when usable skills are already present;
# the init only fails when there is nothing usable at all.
set -eu

SKILLS_DIR=${SKILLS_DIR:-/opt/data/skills}
SKILLS_REPO=${SKILLS_REPO:-git@github.com:BaptTF/agents-skills.git}
SKILLS_BRANCH=${SKILLS_BRANCH:-main}
DEPLOY_KEY=${DEPLOY_KEY:-/deploy-key/id_ed25519}
CONFIG_SRC=${CONFIG_SRC-/config-template/config.yaml}
CONFIG_DST=${CONFIG_DST:-/opt/data/config.yaml}
APP_UID=${APP_UID:-10000}
FETCH_TIMEOUT=${FETCH_TIMEOUT:-90}
GITHUB_HOSTKEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

log() { echo "init-skills: $*" >&2; }

has_skills() {
  [ -n "$(find "$SKILLS_DIR" -mindepth 2 -maxdepth 2 -name SKILL.md -print 2>/dev/null | head -n 1)" ]
}

finish() {
  # best effort: as non-root, chown fails on files owned by another uid
  chown -R "$APP_UID:$APP_UID" "$SKILLS_DIR" 2>/dev/null \
    || log "WARNING: could not chown all of $SKILLS_DIR to $APP_UID (not root?)"
  exit 0
}

degrade() {
  if has_skills; then
    log "WARNING: $* - starting with the skills already on disk"
    finish
  fi
  log "ERROR: $* - and no usable skills on disk"
  exit 1
}

# 1. config
if [ -n "$CONFIG_SRC" ]; then
  cp "$CONFIG_SRC" "$CONFIG_DST"
  chown "$APP_UID:$APP_UID" "$CONFIG_DST" 2>/dev/null \
    || log "WARNING: could not chown $CONFIG_DST to $APP_UID"
fi

# 2. ssh material: container-private tmpdir, never on the PVC
umask 077
SSH_DIR=$(mktemp -d)
trap 'rm -rf "$SSH_DIR"' EXIT
cp "$DEPLOY_KEY" "$SSH_DIR/id"
printf '%s\n' "$GITHUB_HOSTKEY" > "$SSH_DIR/known_hosts"
umask 022
# -F /dev/null: ignore any ~/.ssh/config on the PVC (HOME=/opt/data), whose
# owner/mode may make ssh refuse to run
export GIT_SSH_COMMAND="ssh -F /dev/null -i $SSH_DIR/id -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
export GIT_TERMINAL_PROMPT=0
# checkout may be owned by another uid than ours: trust it for this run only
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$SKILLS_DIR"

mkdir -p "$SKILLS_DIR"
cd "$SKILLS_DIR"

# 3. make the repo usable whatever state a previous (interrupted) init left
if [ -e .git ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
  bad=".git.broken-$(date +%Y%m%d%H%M%S)"
  log "unusable .git, moving it to $bad (working tree kept)"
  mv .git "$bad"
fi
rm -f .git/index.lock .git/shallow.lock .git/config.lock .git/HEAD.lock 2>/dev/null || true
git init -q -b "$SKILLS_BRANCH" 2>/dev/null || git init -q || degrade "git init in $SKILLS_DIR failed"
git remote set-url origin "$SKILLS_REPO" 2>/dev/null || git remote add origin "$SKILLS_REPO" \
  || degrade "could not set the origin remote"

# 4. fetch (bounded)
if ! timeout "$FETCH_TIMEOUT" git fetch -q --depth 1 --no-tags origin "$SKILLS_BRANCH"; then
  degrade "fetch of $SKILLS_REPO $SKILLS_BRANCH failed"
fi
new=$(git rev-parse FETCH_HEAD) || degrade "no FETCH_HEAD after fetch"

# 5. apply
if ! old=$(git rev-parse -q --verify 'HEAD^{commit}'); then
  # unborn branch (empty dir, or files left by a previous non-git sync):
  # adopt upstream in the index, keep any existing file as a local edit,
  # and write only the files that are missing.
  git reset -q "$new" || degrade "bootstrap reset to $new failed"
  git ls-files -z --deleted | xargs -0 -r git checkout -q -- \
    || degrade "bootstrap checkout of missing files failed"
  log "bootstrapped at $new"
elif [ "$old" = "$new" ]; then
  log "up to date ($new)"
else
  # Two-tree merge: moves the tree old->new, keeps unrelated local edits and
  # refuses (without touching anything) if a local edit or untracked file
  # would be overwritten. Needs no common history, so it works with --depth 1
  # (merge --ff-only does not).
  git update-index -q --refresh || true
  if git read-tree -m -u "$old" "$new"; then
    git update-ref "refs/heads/$SKILLS_BRANCH" "$new" \
      && git symbolic-ref HEAD "refs/heads/$SKILLS_BRANCH" \
      || degrade "could not move $SKILLS_BRANCH to $new"
    log "updated $old -> $new"
  else
    log "WARNING: local edits conflict with upstream $new, keeping $old"
  fi
fi
finish

#!/bin/sh
set -eu
mkdir -p /tmp/ssh
cp /deploy-key/id_ed25519 /tmp/ssh/id_ed25519
chmod 600 /tmp/ssh/id_ed25519
printf '%s\n' 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > /tmp/ssh/known_hosts
export GIT_SSH_COMMAND="ssh -i /tmp/ssh/id_ed25519 -o UserKnownHostsFile=/tmp/ssh/known_hosts -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
if [ ! -d /www/.git ]; then
  git clone --depth 1 --branch site git@github.com:rjullien/camille-potager.git /www
fi
# Recipes at camille.bapttf.com/recettes/: public repo, cloned over HTTPS (no key).
# Untracked in the potager checkout, so the reset --hard below leaves it alone.
RECETTES_REPO=https://github.com/rjullien/camille-recettes.git
if [ ! -d /www/recettes/.git ]; then
  rm -rf /www/recettes
  git clone --depth 1 --branch main "$RECETTES_REPO" /www/recettes || echo "recettes clone failed, retrying later" >&2
fi
chmod -R a+rX /www
if [ "${GIT_PULL_ONCE:-}" = "1" ]; then
  exit 0
fi
while true; do
  if git -C /www fetch --depth 1 origin site && git -C /www reset --hard FETCH_HEAD; then
    chmod -R a+rX /www
    echo "synced $(git -C /www rev-parse --short HEAD)"
  else
    echo "git sync failed, retrying in 60s" >&2
  fi
  if [ ! -d /www/recettes/.git ]; then
    rm -rf /www/recettes
    git clone --depth 1 --branch main "$RECETTES_REPO" /www/recettes || true
  fi
  if git -C /www/recettes fetch --depth 1 origin main && git -C /www/recettes reset --hard FETCH_HEAD; then
    chmod -R a+rX /www/recettes
    echo "recettes synced $(git -C /www/recettes rev-parse --short HEAD)"
  else
    echo "recettes sync failed, retrying in 60s" >&2
  fi
  sleep 60
done

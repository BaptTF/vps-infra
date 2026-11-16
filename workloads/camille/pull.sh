#!/bin/sh
set -eu
mkdir -p /tmp/ssh
cp /deploy-key/id_ed25519 /tmp/ssh/id_ed25519
chmod 600 /tmp/ssh/id_ed25519
printf '%s\n' 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > /tmp/ssh/known_hosts
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/www
export GIT_SSH_COMMAND="ssh -i /tmp/ssh/id_ed25519 -o UserKnownHostsFile=/tmp/ssh/known_hosts -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
if [ ! -d /www/.git ]; then
  git clone --depth 1 --branch site git@github.com:rjullien/camille-potager.git /www
fi
find /www -mindepth 1 -exec chmod a+rX {} +
if [ "${GIT_PULL_ONCE:-}" = "1" ]; then
  exit 0
fi
# Only reset when the site branch moved: the chmod above bumps every ctime, so an
# unconditional reset --hard rewrote all files each minute and hit the CPU limit.
while true; do
  if git -C /www fetch --quiet --depth 1 origin site; then
    if [ "$(git -C /www rev-parse HEAD)" != "$(git -C /www rev-parse FETCH_HEAD)" ]; then
      if git -C /www reset --quiet --hard FETCH_HEAD; then
        find /www -mindepth 1 -exec chmod a+rX {} +
        echo "synced $(git -C /www rev-parse --short HEAD)"
      else
        echo "git reset failed, retrying in 60s" >&2
      fi
    fi
  else
    echo "git sync failed, retrying in 60s" >&2
  fi
  sleep 60
done

#!/bin/sh
# rest-server on the DS218play. DSM Task Scheduler runs this at boot as Baptiste
# and the script stays in the foreground. Tailscale on this NAS is userspace
# (no TUN), so the append-only port is published with tailscale serve, which
# needs root once. The prune listener stays on localhost.
set -u

HOME_DIR=/var/services/homes/Baptiste
BIN=$HOME_DIR/bin/rest-server
DATA=$HOME_DIR/restic
AUTH=$HOME_DIR/.config/k3s.htpasswd
TAILSCALE=/usr/local/bin/tailscale

die() {
  echo "rest-serve: $*" >&2
  exit 1
}

stop() {
  for name in append prune; do
    pidfile=$DATA/$name.pid
    if [ -f "$pidfile" ]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
      rm -f "$pidfile"
    fi
  done
}

start() {
  name=$1
  shift
  "$BIN" "$@" --log "$DATA/$name.log" &
  echo $! > "$DATA/$name.pid"
}

[ -x "$BIN" ] || die "binaire absent ($BIN)"
[ -f "$AUTH" ] || die "htpasswd absent ($AUTH)"
[ -x "$TAILSCALE" ] || die "tailscale absent ($TAILSCALE)"
mkdir -p "$DATA" || die "dossier inaccessible ($DATA)"

i=0
while ! "$TAILSCALE" ip -4 >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 30 ] || die "tailscaled pas prêt après 60 s"
  sleep 2
done

trap stop EXIT INT TERM

start append \
  --path "$DATA" --htpasswd-file "$AUTH" --private-repos \
  --listen 127.0.0.1:8000 --append-only
start prune \
  --path "$DATA" --htpasswd-file "$AUTH" --private-repos \
  --listen 127.0.0.1:8001

sleep 1
for name in append prune; do
  kill -0 "$(cat "$DATA/$name.pid")" 2>/dev/null \
    || die "$name s'est arrêté, voir $DATA/$name.log"
done

# Userspace Tailscale has no local 100.x address. serve persists in tailscaled.
if ! "$TAILSCALE" serve --bg --yes --tcp 8000 127.0.0.1:8000; then
  echo "rest-serve: tailscale serve a échoué. Lancer une fois en root : tailscale serve --bg --yes --tcp 8000 127.0.0.1:8000" >&2
fi

while true; do
  for name in append prune; do
    kill -0 "$(cat "$DATA/$name.pid")" 2>/dev/null \
      || die "$name s'est arrêté, voir $DATA/$name.log"
  done
  sleep 15
done

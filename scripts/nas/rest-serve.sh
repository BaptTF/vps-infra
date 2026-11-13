#!/bin/sh
# Attente de l'adresse Tailscale sur tailscale0 (120 tentatives max, 5 s d'intervalle = 10 min).
# L'horloge RTC repart en 2016 au boot : Tailscale peut mettre plusieurs minutes
# à se connecter après le sync NTP avant d'obtenir son adresse 100.x.
_ts_attempt=0
while [ "$_ts_attempt" -lt 120 ]; do
  if ip -4 addr show tailscale0 2>/dev/null | grep -Fq 100.75.160.28; then
    break
  fi
  _ts_attempt=$((_ts_attempt + 1))
  sleep 5
done
if [ "$_ts_attempt" -ge 120 ]; then
  echo "rest-serve: 100.75.160.28 absente de tailscale0 apres 600 s" >&2
  exit 1
fi

# rest-server on the DS218play. DSM Task Scheduler runs this at boot as Baptiste
# and the script stays in the foreground. Tailscale runs in TUN mode (set up by
# the tailscale-tun boot task), so both listeners bind directly to the tailnet
# address.
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
  --listen 100.75.160.28:8000 --append-only
start prune \
  --path "$DATA" --htpasswd-file "$AUTH" --private-repos \
  --listen 100.75.160.28:8001

sleep 1
for name in append prune; do
  kill -0 "$(cat "$DATA/$name.pid")" 2>/dev/null \
    || die "$name s'est arrêté, voir $DATA/$name.log"
done

while true; do
  for name in append prune; do
    kill -0 "$(cat "$DATA/$name.pid")" 2>/dev/null \
      || die "$name s'est arrêté, voir $DATA/$name.log"
  done
  sleep 15
done

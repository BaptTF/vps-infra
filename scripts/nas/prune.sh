#!/bin/sh
# Run on the Home Assistant Pi, which already has restic. The NAS does not:
# it has no RAM for a restic process. Reach the prune listener with
#   ssh -N -L 8001:127.0.0.1:8001 dsplay
# REST_PASSWORD is the htpasswd password. RESTIC_PASSWORD is the repository password.
set -eu

: "${REST_PASSWORD:?}"
: "${RESTIC_PASSWORD:?}"

export RESTIC_REPOSITORY="rest:http://k3s:${REST_PASSWORD}@127.0.0.1:8001/k3s"
export RESTIC_PASSWORD

restic forget --keep-daily 14 --keep-weekly 8 --prune
restic check

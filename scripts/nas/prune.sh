#!/bin/sh
# Run on the NAS. sshd has AllowTcpForwarding no, so the Pi cannot tunnel to
# 127.0.0.1:8001. REST_PASSWORD is the htpasswd password. RESTIC_PASSWORD is
# the repository password.
set -eu

: "${REST_PASSWORD:?}"
: "${RESTIC_PASSWORD:?}"

export RESTIC_REPOSITORY="rest:http://k3s:${REST_PASSWORD}@127.0.0.1:8001/k3s"
export RESTIC_PASSWORD

restic forget --keep-daily 14 --keep-weekly 8 --prune
restic check

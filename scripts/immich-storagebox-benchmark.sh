#!/usr/bin/env bash
set -euo pipefail

: "${STORAGEBOX_HOST:?Set STORAGEBOX_HOST, for example uXXXXX.your-storagebox.de}"
: "${STORAGEBOX_USER:?Set STORAGEBOX_USER}"
: "${STORAGEBOX_PASSWORD:?Set STORAGEBOX_PASSWORD}"

REMOTE_DIR="${REMOTE_DIR:-immich-benchmark}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/immich-storagebox-benchmark}"
STORAGEBOX_SHARE="${STORAGEBOX_SHARE:-backup}"
SMB_SOURCE="//${STORAGEBOX_HOST}/${STORAGEBOX_SHARE}"
TEST_DIR="${MOUNT_POINT}/${REMOTE_DIR}"

cleanup() {
  if mountpoint -q "${MOUNT_POINT}"; then
    sudo umount "${MOUNT_POINT}"
  fi
}
trap cleanup EXIT

echo "Checking network path to ${STORAGEBOX_HOST}"
ping -c 5 "${STORAGEBOX_HOST}" || true
nc -vz "${STORAGEBOX_HOST}" 445

echo "Mounting ${SMB_SOURCE} at ${MOUNT_POINT}"
sudo mkdir -p "${MOUNT_POINT}"
sudo mount -t cifs "${SMB_SOURCE}" "${MOUNT_POINT}" \
  -o "username=${STORAGEBOX_USER},password=${STORAGEBOX_PASSWORD},vers=3.1.1,uid=$(id -u),gid=$(id -g),dir_mode=0775,file_mode=0664,noserverino,cache=strict"

mkdir -p "${TEST_DIR}"

echo "Sequential write test"
dd if=/dev/zero of="${TEST_DIR}/write-test.bin" bs=16M count=16 conv=fdatasync status=progress

echo "Sequential read test"
dd if="${TEST_DIR}/write-test.bin" of=/dev/null bs=16M status=progress

echo "Small file create/list/delete test"
SMALL_DIR="${TEST_DIR}/small-files"
rm -rf "${SMALL_DIR}"
mkdir -p "${SMALL_DIR}"
time sh -c "for i in \$(seq 1 1000); do printf test > '${SMALL_DIR}/file-\${i}.txt'; done"
time ls -la "${SMALL_DIR}" >/dev/null
time rm -rf "${SMALL_DIR}"

rm -f "${TEST_DIR}/write-test.bin"
echo "Benchmark complete"

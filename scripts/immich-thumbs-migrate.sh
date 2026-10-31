#!/usr/bin/env bash
set -euo pipefail
# Copies thumbs to the Storage Box; pause Immich thumbnail jobs first, re-run rsync after cutover if needed.

NAMESPACE="${NAMESPACE:-immich}"
MIGRATE_JOB="immich-migrate-thumbs"
VERIFY_JOB="immich-verify-thumbs"
CLEANUP_JOB="immich-cleanup-thumbs"

echo "=== Phase 1: Migrate thumbs from local PVC to storagebox ==="
echo ""

kubectl -n "${NAMESPACE}" delete job "${MIGRATE_JOB}" --ignore-not-found

kubectl -n "${NAMESPACE}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${MIGRATE_JOB}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: rsync
          image: alpine:3.22
          command:
            - sh
            - -c
            - |
              set -eux
              apk add --no-cache rsync
              mkdir -p /dest/thumbs
              rsync -aH --info=progress2 /source/thumbs/ /dest/thumbs/
              echo "=== Migration complete ==="
              echo "Source:"
              du -sh /source/thumbs/
              find /source/thumbs -type f | wc -l
              echo "Destination:"
              du -sh /dest/thumbs/
              find /dest/thumbs -type f | wc -l
          volumeMounts:
            - name: source
              mountPath: /source
              readOnly: true
            - name: dest
              mountPath: /dest
      volumes:
        - name: source
          persistentVolumeClaim:
            claimName: immich-library
        - name: dest
          persistentVolumeClaim:
            claimName: immich-storagebox
EOF

echo "Waiting for migration job to complete..."
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${MIGRATE_JOB}" --timeout=24h
echo ""
echo "Migration job logs:"
kubectl -n "${NAMESPACE}" logs "job/${MIGRATE_JOB}" --tail=20
echo ""

echo "=== Phase 1 complete ==="
echo ""
echo "Now push the commit with the new volumeMount in server.yaml and wait for ArgoCD to redeploy."
read -rp "Press Enter once immich-server has been redeployed with the new mount... "
echo ""

echo "=== Phase 2: Verify data integrity ==="
echo ""

kubectl -n "${NAMESPACE}" delete job "${VERIFY_JOB}" --ignore-not-found

kubectl -n "${NAMESPACE}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${VERIFY_JOB}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: verify
          image: alpine:3.22
          command:
            - sh
            - -c
            - |
              set -eu
              SRC_SIZE=\$(du -sb /source/thumbs/ | cut -f1)
              DST_SIZE=\$(du -sb /dest/thumbs/ | cut -f1)
              SRC_COUNT=\$(find /source/thumbs -type f | wc -l)
              DST_COUNT=\$(find /dest/thumbs -type f | wc -l)

              echo "Source: \${SRC_COUNT} entries, \${SRC_SIZE} bytes"
              echo "Dest:   \${DST_COUNT} entries, \${DST_SIZE} bytes"

              if [ "\${DST_COUNT}" -ge "\${SRC_COUNT}" ] && [ "\${DST_SIZE}" -ge "\${SRC_SIZE}" ]; then
                echo "VERIFY OK: dest >= source (new thumbs may be written after cutover)"
                exit 0
              else
                echo "VERIFY FAILED: mismatch detected!"
                echo "Diff (in source but not in dest):"
                (cd /source/thumbs && find . -type f | sort) > /tmp/src
                (cd /dest/thumbs && find . -type f | sort) > /tmp/dst
                comm -23 /tmp/src /tmp/dst | head -50
                exit 1
              fi
          volumeMounts:
            - name: source
              mountPath: /source
              readOnly: true
            - name: dest
              mountPath: /dest
              readOnly: true
      volumes:
        - name: source
          persistentVolumeClaim:
            claimName: immich-library
        - name: dest
          persistentVolumeClaim:
            claimName: immich-storagebox
EOF

echo "Waiting for verification job..."
if kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${VERIFY_JOB}" --timeout=600s; then
  echo ""
  kubectl -n "${NAMESPACE}" logs "job/${VERIFY_JOB}"
  echo ""
  echo "=== Phase 2 complete: verification passed ==="
else
  echo ""
  echo "Verification FAILED! Logs:"
  kubectl -n "${NAMESPACE}" logs "job/${VERIFY_JOB}"
  echo ""
  echo "Aborting. Do NOT delete the source data."
  exit 1
fi

echo ""
echo "=== Phase 3: Cleanup old data from local PVC ==="
read -rp "Delete thumbs from local PVC? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Skipped cleanup. You can manually delete later."
  exit 0
fi

kubectl -n "${NAMESPACE}" delete job "${CLEANUP_JOB}" --ignore-not-found

kubectl -n "${NAMESPACE}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${CLEANUP_JOB}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: cleanup
          image: alpine:3.22
          command:
            - sh
            - -c
            - |
              set -eux
              echo "Before cleanup:"
              du -sh /data/thumbs/
              rm -rf /data/thumbs/*
              echo "After cleanup:"
              du -sh /data/thumbs/
              echo "Cleanup complete"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: immich-library
EOF

echo "Waiting for cleanup job..."
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${CLEANUP_JOB}" --timeout=600s
kubectl -n "${NAMESPACE}" logs "job/${CLEANUP_JOB}"
echo ""
echo "=== Done! thumbs is now served from the storagebox ==="

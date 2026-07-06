#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-immich}"
MIGRATE_JOB="immich-migrate-encoded-video"
VERIFY_JOB="immich-verify-encoded-video"
CLEANUP_JOB="immich-cleanup-encoded-video"

echo "=== Phase 1: Migrate encoded-video from local PVC to storagebox ==="
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
              mkdir -p /dest/encoded-video
              rsync -aH --info=progress2 /source/encoded-video/ /dest/encoded-video/
              echo "=== Migration complete ==="
              echo "Source:"
              du -sh /source/encoded-video/
              ls /source/encoded-video/ | wc -l
              echo "Destination:"
              du -sh /dest/encoded-video/
              ls /dest/encoded-video/ | wc -l
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

echo "Waiting for migration job to complete (this may take a while for 44G)..."
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
              SRC_SIZE=\$(du -sb /source/encoded-video/ | cut -f1)
              DST_SIZE=\$(du -sb /dest/encoded-video/ | cut -f1)
              SRC_COUNT=\$(ls /source/encoded-video/ | wc -l)
              DST_COUNT=\$(ls /dest/encoded-video/ | wc -l)

              echo "Source: \${SRC_COUNT} entries, \${SRC_SIZE} bytes"
              echo "Dest:   \${DST_COUNT} entries, \${DST_SIZE} bytes"

              if [ "\${SRC_COUNT}" -eq "\${DST_COUNT}" ] && [ "\${SRC_SIZE}" -eq "\${DST_SIZE}" ]; then
                echo "VERIFY OK: entry count and size match"
                exit 0
              else
                echo "VERIFY FAILED: mismatch detected!"
                echo "Diff (in source but not in dest):"
                comm -23 <(ls /source/encoded-video/ | sort) \
                         <(ls /dest/encoded-video/ | sort) | head -50
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
read -rp "Delete encoded-video from local PVC to free 44G? [y/N] " confirm
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
              du -sh /data/encoded-video/
              rm -rf /data/encoded-video/*
              echo "After cleanup:"
              du -sh /data/encoded-video/
              echo "Cleanup complete - 44G freed"
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
echo "=== Done! encoded-video is now served from the storagebox ==="

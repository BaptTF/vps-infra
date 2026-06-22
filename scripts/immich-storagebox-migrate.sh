#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-immich}"
JOB_NAME="${JOB_NAME:-immich-storagebox-migrate}"

echo "This job copies /data/upload, /data/library and /data/family from immich-library to immich-storagebox."
echo "Scale Immich and FileBrowser down first, and keep ArgoCD auto-sync paused while the job runs."

kubectl -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found

kubectl -n "${NAMESPACE}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
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
              mkdir -p /dest/upload /dest/library /dest/family /dest/family/inbox /dest/family/library
              for dir in upload library family; do
                if [ -d "/source/\${dir}" ]; then
                  rsync -aH --info=progress2 "/source/\${dir}/" "/dest/\${dir}/"
                fi
              done
              find /dest -maxdepth 2 -type d -print
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

kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${JOB_NAME}" --timeout=24h
kubectl -n "${NAMESPACE}" logs "job/${JOB_NAME}"

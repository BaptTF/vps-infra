#!/usr/bin/env bash
set -euo pipefail
# Copies thumbs to the Storage Box with parallel rsync. SMB latency to the box limits each rsync to a few files per second.
# Runs: bulk copy while Immich is live, catch-up pass with the thumbnail queue paused, cutover, pass with --update, cleanup.

NAMESPACE="${NAMESPACE:-immich}"
JOB="immich-migrate-thumbs"
CLEANUP_JOB="immich-cleanup-thumbs"
PARALLEL="${PARALLEL:-24}"

run_copy() {
  local extra="$1"
  kubectl -n "${NAMESPACE}" delete job "${JOB}" --ignore-not-found
  sed -e "s|__JOB__|${JOB}|" -e "s|__PARALLEL__|${PARALLEL}|" -e "s|__EXTRA__|${extra}|" <<'EOF' | kubectl -n "${NAMESPACE}" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB__
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: rsync
          image: alpine:3.22
          env:
            - name: PARALLEL
              value: "__PARALLEL__"
            - name: RSYNC_EXTRA
              value: "__EXTRA__"
          command:
            - sh
            - -c
            - |
              set -u
              apk add --no-cache rsync findutils >/dev/null
              mkdir -p /dest/thumbs
              cd /source/thumbs
              rsync -rlt $RSYNC_EXTRA --exclude='*/' /source/thumbs/ /dest/thumbs/
              for u in */; do rsync -rlt $RSYNC_EXTRA --exclude='*/' "/source/thumbs/$u" "/dest/thumbs/$u"; done
              for u in */; do for d in "$u"*/; do echo "${d%/}"; done; done > /tmp/units
              export TOTAL=$(wc -l < /tmp/units)
              echo "[plan] $TOTAL units, parallel=$PARALLEL, start $(date -u +%TZ)"
              mkdir -p /tmp/rc
              cat > /tmp/w.sh <<'W'
              u=$1
              rcf=/tmp/rc/$(echo "$u" | tr / _)
              { rsync -rlt --whole-file --inplace $RSYNC_EXTRA --stats "/source/thumbs/$u/" "/dest/thumbs/$u/" > "$rcf.stats" 2>&1; echo $? > "$rcf"; }
              grep -v '^\(Number\|Total\|Literal\|Matched\|File list\|sent\|total\|$\)' "$rcf.stats" | sed "s|^|[$u] |"
              n=$(sed -n 's/^Number of regular files transferred: //p' "$rcf.stats" | tr -d ,)
              echo "$u" >> /tmp/done
              echo "[progress] $(wc -l < /tmp/done)/$TOTAL $u exit=$(cat "$rcf") copied=${n:-?} $(date -u +%TZ)"
              W
              xargs -a /tmp/units -P "$PARALLEL" -n 1 sh /tmp/w.sh
              fail=0
              for f in /tmp/rc/*; do case "$f" in *.stats) continue ;; esac; case "$(cat "$f")" in 0|24) ;; *) fail=1; echo "[failed] $(basename "$f") exit=$(cat "$f")" ;; esac; done
              echo "[total copied] $(sed -n 's/^Number of regular files transferred: //p' /tmp/rc/*.stats | tr -d , | awk '{t+=$1} END {print t}')"
              echo "=== Migration finished fail=$fail $(date -u +%TZ) ==="
              exit "$fail"
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
  echo "Follow with: kubectl -n ${NAMESPACE} logs -f job/${JOB} | grep -v 'copied=0'"
  kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${JOB}" --timeout=48h
  kubectl -n "${NAMESPACE}" logs "job/${JOB}" | grep -E '^\[(failed|total copied)\]|^==='
}

thumbs_queue() {
  kubectl -n "${NAMESPACE}" exec deploy/immich-valkey -- sh -c \
    'echo "paused=$(valkey-cli hget immich_bull:thumbnailGeneration:meta paused) active=$(valkey-cli llen immich_bull:thumbnailGeneration:active)"'
}

echo "=== Phase 1: bulk copy while Immich runs ==="
run_copy ""

echo ""
echo "=== Phase 2: catch-up pass ==="
echo "Pause 'Generate Thumbnails' in Immich (Administration > Jobs). Upload tools such as immich-go can resume it."
read -rp "Press Enter once paused... "
until thumbs_queue | tee /dev/stderr | grep -q 'paused=1 active=0'; do sleep 10; done
run_copy ""

echo ""
echo "=== Phase 3: cutover ==="
echo "Merge the commit that mounts thumbs from the Storage Box on the API and microservices pods, and wait for ArgoCD."
read -rp "Press Enter once both Immich pods run with the new mount... "
run_copy "--update"
echo "Resume 'Generate Thumbnails' in Immich."

echo ""
echo "=== Phase 4: cleanup ==="
echo "Keep the local thumbs until Immich has been checked on the Storage Box. They are the rollback."
read -rp "Delete thumbs from the local PVC? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Skipped cleanup."
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
              du -sh /data/thumbs/
              rm -rf /data/thumbs/*
              du -sh /data/thumbs/
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: immich-library
EOF
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${CLEANUP_JOB}" --timeout=600s
kubectl -n "${NAMESPACE}" logs "job/${CLEANUP_JOB}"
echo "=== Done: thumbs are served from the Storage Box ==="

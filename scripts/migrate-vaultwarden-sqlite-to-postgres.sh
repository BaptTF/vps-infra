#!/bin/bash
# Copy Vaultwarden from /data/db.sqlite3 into the empty postgres database
# `vaultwarden` on postgres-cluster. Run only while the vaultwarden
# deployment is scaled to 0: the PVC is ReadWriteOnce.
#
# Official procedure (unsupported upstream):
# https://github.com/dani-garcia/vaultwarden/wiki/Using-the-PostgreSQL-Backend

set -euo pipefail

NS=vaultwarden
PVC=vaultwarden-data
IMAGE=vaultwarden/server:1.37.4
PGHOST=postgres-cluster-rw.cnpg-system.svc.cluster.local

if kubectl -n "$NS" get deploy vaultwarden -o jsonpath='{.spec.replicas}' | grep -qx 0 \
  && ! kubectl -n "$NS" get pods -l app=vaultwarden --field-selector=status.phase=Running -o name | grep -q .; then
  echo "vaultwarden is stopped"
else
  echo "refusing to run: vaultwarden deployment must be at 0 replicas and have no running pod" >&2
  exit 1
fi

cleanup() {
  kubectl -n "$NS" delete pod vaultwarden-sqlite-checkpoint --ignore-not-found --wait=true
  kubectl -n "$NS" delete pod vaultwarden-schema --ignore-not-found --wait=true
  kubectl -n "$NS" delete pod vaultwarden-pgloader --ignore-not-found --wait=true
}
trap cleanup EXIT

echo "=== checkpoint SQLite WAL ==="
kubectl -n "$NS" delete pod vaultwarden-sqlite-checkpoint --ignore-not-found --wait=true >/dev/null
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: vaultwarden-sqlite-checkpoint
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
    - name: sqlite
      image: alpine:3.22
      command: ["sh", "-c"]
      args:
        - |
          set -eu
          apk add --no-cache sqlite >/dev/null
          sqlite3 /data/db.sqlite3 "PRAGMA wal_checkpoint(TRUNCATE);"
          sqlite3 /data/db.sqlite3 "PRAGMA journal_mode=DELETE;"
          cp -a /data/db.sqlite3 /data/db.sqlite3.pre-pg
          sqlite3 /data/db.sqlite3 "SELECT 'users', count(*) FROM users; SELECT 'ciphers', count(*) FROM ciphers; SELECT 'attachments', count(*) FROM attachments;"
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC}
EOF
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/vaultwarden-sqlite-checkpoint --timeout=180s
echo "--- sqlite counts ---"
kubectl -n "$NS" logs pod/vaultwarden-sqlite-checkpoint

echo "=== create postgres schema with diesel ==="
kubectl -n "$NS" delete pod vaultwarden-schema --ignore-not-found --wait=true >/dev/null
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: vaultwarden-schema
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
    - name: vaultwarden
      image: ${IMAGE}
      env:
        - name: DOMAIN
          value: https://vault.bapttf.com
        - name: DB_USERNAME
          valueFrom:
            secretKeyRef:
              name: vaultwarden-db-secret
              key: username
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: vaultwarden-db-secret
              key: password
        - name: DATABASE_URL
          value: postgresql://\$(DB_USERNAME):\$(DB_PASSWORD)@${PGHOST}:5432/vaultwarden
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC}
EOF

for _ in $(seq 1 60); do
  if kubectl -n "$NS" logs pod/vaultwarden-schema 2>/dev/null | grep -Eq "Listening on|Rocket has launched"; then
    break
  fi
  phase=$(kubectl -n "$NS" get pod vaultwarden-schema -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$phase" = "Failed" ] || [ "$phase" = "Succeeded" ]; then
    kubectl -n "$NS" logs pod/vaultwarden-schema | sed -E 's#postgresql://[^@]+@#postgresql://***@#g'
    echo "schema pod ended before listening (phase=$phase)" >&2
    exit 1
  fi
  sleep 2
done
if ! kubectl -n "$NS" logs pod/vaultwarden-schema 2>/dev/null | grep -Eq "Listening on|Rocket has launched"; then
  kubectl -n "$NS" logs pod/vaultwarden-schema | sed -E 's#postgresql://[^@]+@#postgresql://***@#g'
  echo "schema pod did not start listening" >&2
  exit 1
fi
kubectl -n "$NS" delete pod vaultwarden-schema --wait=true

echo "=== pgloader data only ==="
kubectl -n "$NS" delete pod vaultwarden-pgloader --ignore-not-found --wait=true >/dev/null
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: vaultwarden-pgloader
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
    - name: pgloader
      image: ghcr.io/dimitri/pgloader:latest
      command: ["bash", "-c"]
      env:
        - name: DB_USERNAME
          valueFrom:
            secretKeyRef:
              name: vaultwarden-db-secret
              key: username
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: vaultwarden-db-secret
              key: password
      args:
        - |
          set -eu
          cat > /tmp/bitwarden.load <<ENDLOAD
          LOAD DATABASE
               FROM sqlite:///data/db.sqlite3
               INTO postgresql://\${DB_USERNAME}:\${DB_PASSWORD}@${PGHOST}:5432/vaultwarden
               WITH data only, include no drop, reset sequences
               EXCLUDING TABLE NAMES LIKE '__diesel_schema_migrations'
               ALTER SCHEMA 'bitwarden' RENAME TO 'public'
          ;
          ENDLOAD
          pgloader --verbose /tmp/bitwarden.load
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC}
EOF
if ! kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/vaultwarden-pgloader --timeout=300s; then
  kubectl -n "$NS" logs pod/vaultwarden-pgloader | sed -E 's#postgresql://[^@[:space:]]+@#postgresql://***@#g'
  exit 1
fi
echo "--- pgloader summary ---"
kubectl -n "$NS" logs pod/vaultwarden-pgloader | sed -E 's#postgresql://[^@[:space:]]+@#postgresql://***@#g' | tail -n 40

echo "=== postgres counts ==="
kubectl -n cnpg-system exec postgres-cluster-1 -c postgres -- \
  psql -U postgres -d vaultwarden -c "SELECT 'users' AS tbl, count(*) FROM users UNION ALL SELECT 'ciphers', count(*) FROM ciphers UNION ALL SELECT 'attachments', count(*) FROM attachments;"

echo "=== migration finished ==="
echo "Compare the sqlite counts above with the postgres counts before pointing Vaultwarden at DATABASE_URL."

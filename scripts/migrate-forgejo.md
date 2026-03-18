### The Docker-to-k3s Forgejo Migration Playbook

This assumes your Docker Compose stack is currently running and your k3s cluster is accessible via `kubectl`.

#### Phase 1: Extract and Translate Data (Docker)
Run these commands on your old Docker host to generate a PostgreSQL-compatible dump from your SQLite database.

```bash
#!/bin/bash
# 1. Generate the Postgres-dialect dump inside the running Docker container
docker exec -it forgejo bash -c 'forgejo dump --database postgres -c /data/gitea/conf/app.ini'

# 2. Find the generated zip file name
DUMP_FILE=$(docker exec -it forgejo ls -1 | grep forgejo-dump | head -n 1)

# 3. Copy the zip file out to your host
docker cp forgejo:/$DUMP_FILE /tmp/forgejo-dump.zip

# 4. Extract it to a working directory
mkdir -p /tmp/forgejo_migration
unzip /tmp/forgejo-dump.zip -d /tmp/forgejo_migration

# 5. Stop the Docker Compose stack permanently so no new data is written
docker compose stop server
```

#### Phase 2: Prepare Kubernetes (k3s)
Move your `/tmp/forgejo_migration` folder to your k3s machine (if it's a different server), and spin up the baseline Kubernetes resources.

```bash
# 1. Apply your ArgoCD/Kustomize manifests to create PVCs, Postgres, and Forgejo
kubectl apply -k .

# 2. Wait for the pods to initialize, then immediately scale Forgejo to 0
# (This prevents it from locking the database or writing conflicting data)
kubectl scale deployment forgejo --replicas=0 -n forgejo
```

#### Phase 3: The CloudNativePG Database Migration
We need to wipe the empty database Forgejo auto-created, stream the translated data in, and fix the table ownership.

```bash
# 1. Drop and recreate the database as the Postgres superuser
kubectl exec -it -n cnpg-system postgres-cluster-1 -- psql -U postgres -c "
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'forgejo' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS forgejo;
CREATE DATABASE forgejo WITH OWNER forgejo;
"

# 2. Stream the SQL dump directly into the new database
kubectl exec -i -n cnpg-system postgres-cluster-1 -- psql -U postgres -d forgejo < /tmp/forgejo_migration/forgejo-db.sql

# 3. Fix the table and sequence ownership (Hand the keys to the 'forgejo' user)
kubectl exec -it -n cnpg-system postgres-cluster-1 -- psql -U postgres -d forgejo -c "
GRANT ALL ON SCHEMA public TO forgejo;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO forgejo;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO forgejo;
DO \$\$ 
DECLARE 
    r RECORD; 
BEGIN 
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP 
        EXECUTE 'ALTER TABLE public.' || quote_ident(r.tablename) || ' OWNER TO forgejo'; 
    END LOOP; 
    FOR r IN (SELECT relname FROM pg_class WHERE relkind = 'S' AND relnamespace = 'public'::regnamespace) LOOP 
        EXECUTE 'ALTER SEQUENCE public.' || quote_ident(r.relname) || ' OWNER TO forgejo'; 
    END LOOP; 
END \$\$;
"
```

#### Phase 4: Migrate Physical Data (PVC)
Scale Forgejo back up so the pod is running, then copy the physical files into the correct directories.

```bash
# 1. Scale Forgejo back up to 1 replica so we have a target for 'kubectl cp'
kubectl scale deployment forgejo --replicas=1 -n forgejo

# Wait for the pod to be 'Running' (it might crashloop briefly if it can't find repos, that's fine)
sleep 15 

# 2. Create the exact folder structure Forgejo expects
kubectl exec -it -n forgejo deployment/forgejo -- mkdir -p /data/gitea /data/git/gitea-repositories

# 3. Copy attachments, avatars, and user uploads
kubectl cp /tmp/forgejo_migration/data/. forgejo/$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo -o jsonpath="{.items[0].metadata.name}"):/data/gitea/

# 4. Copy the raw Git repositories (Notice we map local 'repos' to remote 'gitea-repositories')
kubectl cp /tmp/forgejo_migration/repos/. forgejo/$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo -o jsonpath="{.items[0].metadata.name}"):/data/git/gitea-repositories/
```

#### Phase 5: Final Reboot
Reboot the deployment so Forgejo does a fresh scan of the filesystem and syncs everything with the newly imported database.

```bash
# Restart the deployment
kubectl rollout restart deployment forgejo -n forgejo

# Watch the logs to confirm a clean startup
kubectl logs -f -n forgejo deployment/forgejo
```

---

You now have a production-grade, GitOps-managed Forgejo instance running on Kubernetes with a robust CloudNativePG backend. 
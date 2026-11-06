# ArgoCD Helm Chart Upgrade — v9.7.1 → v10.3.3

## Versions concernées

| Composant | Avant | Après |
|-----------|-------|-------|
| Helm chart | 9.7.1 | 10.3.3 |
| ArgoCD app | v3.4.x | v3.5.1 |
| Redis | ancienne | 8.6.4 |

## Breaking change (chart 10.0.0)

`global.networkPolicy.create` passe de `false` à `true` par défaut.

5 NetworkPolicies sont créées :

| NetworkPolicy | Protège | Ingress autorisé |
|---|---|---|
| `argocd-server` | UI/API | `ingress: - {}` → **ouvert à tout** |
| `argocd-application-controller` | Controller | Metrics (tout namespace) |
| `argocd-repo-server` | Repo server | Server + Controller + Notifications + AppSet + Metrics |
| `argocd-redis` | Redis | Server + Repo-server + Controller |
| `argocd-notifications-controller` | Notifications | Metrics (tout namespace) |

**Verdict** : `argocd-server` est ouvert (`ingress: - {}`), Traefik et Tailscale
ne sont pas bloqués. Le fix `networkPolicy.create: false` dans values.yaml est
une sécurité supplémentaire (ceinture + bretelles).

## Risque principal : ArgoCD se self-manage

L'app `apps/argocd.yaml` pointe vers `system/argocd/` avec :
- `syncPolicy.automated.prune: true`
- `syncPolicy.automated.selfHeal: true`
- `ServerSideApply=true`

**Dès le merge sur main, ArgoCD va auto-appliquer le changement** → il se kill
et se redéploie en v3.5.1.

## Scénarios de risque

| Risque | Description | Probabilité | Sévérité |
|--------|-------------|-------------|----------|
| ArgoCD crash loop | Nouveaux pods v3.5.1 ne démarrent pas | Faible | 🔴 Critique |
| Prune destructif | Chart v10 renomme une resource → prune supprime l'ancien avant le nouveau | Faible | 🔴 Critique |
| Redis incompatible | Redis 8.6.4 format non rétrocompatible | Très faible | 🟡 Moyen |
| NP bloque pendant transition | NP appliquée avant que les nouveaux pods soient labellisés | Très faible | 🟡 Moyen |
| **Succès silencieux** | L'upgrade passe sans problème (cas le plus probable pour un minor 3.4→3.5) | **Élevée** | 🟢 |

## Facteurs rassurants

- Même major d'ArgoCD (v3.4 → v3.5) — pas de migration CRD majeure
- Le changelog chart 10.x ne mentionne aucun renommage de resources
- `ServerSideApply=true` est déjà configuré (évite les conflits de champs)
- Des milliers de clusters font ce type d'auto-upgrade sans incident

---

## Procédure d'upgrade

### Option A — Laisser le auto-sync faire (confiant)

1. Merger la PR #152 (ce fix NP)
2. Merger la PR #112 (chart bump)
3. Surveiller : `kubectl get pods -n argocd -w`
4. Si tout Running → regénérer le bootstrap :
   ```bash
   kustomize build --enable-helm system/argocd/ > argocd-bootstrap.yaml
   git add argocd-bootstrap.yaml
   git commit -m "build(argocd): regenerate bootstrap for chart v10.3.3"
   git push
   ```
5. Vérifier l'UI : https://argocd.bapttf.com

### Option B — Upgrade contrôlé (recommandé)

```bash
# 1. Suspendre le auto-sync
kubectl patch app argocd-system -n argocd --type merge \
  -p '{"spec":{"syncPolicy":null}}'

# 2. Merger PR #152 + PR #112 sur GitHub

# 3. Regénérer et appliquer manuellement
kustomize build --enable-helm system/argocd/ > argocd-bootstrap.yaml
kubectl apply --server-side --force-conflicts -f argocd-bootstrap.yaml

# 4. Vérifier
kubectl get pods -n argocd
kubectl logs -n argocd deployment/argocd-server --tail=20
# Tester l'UI : https://argocd.bapttf.com

# 5. Réactiver le auto-sync
kubectl patch app argocd-system -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["ServerSideApply=true"]}}}'

# 6. Commit le bootstrap regénéré
git add argocd-bootstrap.yaml
git commit -m "build(argocd): regenerate bootstrap for chart v10.3.3"
git push
```

## Rollback si ça casse

```bash
# Le argocd-bootstrap.yaml dans le repo est encore en v9.7.1
# L'appliquer restaure l'ancienne version immédiatement :
kubectl apply --server-side --force-conflicts -f \
  https://raw.githubusercontent.com/BaptTF/vps-infra/main/argocd-bootstrap.yaml
```

## Checklist post-merge

- [ ] Pods ArgoCD tous Running
- [ ] UI https://argocd.bapttf.com accessible
- [ ] `argocd-bootstrap.yaml` regénéré et pushé
- [ ] Toutes les apps en Healthy/Synced dans l'UI

---

*Ce fichier peut être supprimé après l'upgrade.*

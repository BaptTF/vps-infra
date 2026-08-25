# Exporter un secret Infisical vers un pod

## Description
Rendre une clé stockée dans Infisical disponible comme variable d'environnement
dans un pod de ce cluster. Couvre le choix entre `envFrom` et `secretKeyRef`, les
pièges de précédence, et la vérification.

## When to Use
- Ajouter une clé d'API à un service existant (agent Hermès, backend, worker…)
- Diagnostiquer « j'ai mis la clé dans Infisical mais l'app ne la voit pas »
- Reviewer une PR qui ajoute un `envFrom` sur un deployment

## Le modèle en 3 étages

```
Infisical (projet infrastructure / env prod / path /agents/xxx)
   │  ← InfisicalSecret CR (infisical-secret.yaml)
   ▼
Secret Kubernetes (namespace du service)
   │  ← envFrom: secretRef   OU   env: valueFrom: secretKeyRef
   ▼
Variables d'environnement du conteneur
```

Un `Secret` K8s stocke ses valeurs en base64 dans le champ `data:`. **Ne jamais
dé-base64 à la main** : `secretKeyRef` et `envFrom` décodent automatiquement. Le
base64 n'est qu'un encodage de transport YAML.

## Étape 1 — Vérifier que le path Infisical est déjà syncé

Chaque service a son `infisical-secret.yaml`. Repérer le `secretsPath` et le
`secretName` produit :

```bash
grep -rn "secretsPath\|secretName" workloads/<service>/**/infisical-secret.yaml
```

Deux services peuvent partager un path. Exemple réel : `assisted-teacher` et
`hermes-lya` pointent tous les deux sur `/agents/hermes-lya`, donc une clé ajoutée
là atterrit dans **deux** secrets K8s, dans deux namespaces différents.

À l'inverse, des services qui se ressemblent peuvent avoir des paths distincts :
`hermes-lya` → `/agents/hermes-lya`, `hermes-leo` → `/agents/nullclaw-leo`. Une
clé à ajouter « sur tous les Hermès » doit être ajoutée **dans chaque path**.

Si le path est déjà syncé, ajouter la clé dans l'UI Infisical suffit côté secret :
l'operator la propage, et l'annotation `secrets.infisical.com/auto-reload: "true"`
sur le deployment déclenche un rollout.

## Étape 2 — Choisir le mode d'export

### `secretKeyRef` (à privilégier)

```yaml
env:
  - name: BRAVE_SEARCH_API_KEY
    valueFrom:
      secretKeyRef:
        name: assisted-teacher-secret
        key: BRAVE_SEARCH_API_KEY
        optional: true   # le pod démarre même si la clé n'existe pas encore
```

Chirurgical : on exporte exactement la clé voulue, on lit dans le manifest ce que
le pod reçoit. **C'est le défaut à retenir.**

Sans `optional: true`, une clé absente met le pod en `CreateContainerConfigError`
et il ne démarre pas.

### `envFrom` (tout le secret d'un coup)

```yaml
envFrom:
  - secretRef:
      name: hermes-lya-secret
```

Justifié quand l'application consomme *nativement* beaucoup de clés du même
secret sans qu'on veuille les énumérer — c'est le cas des agents Hermès
(`hermes-lya`, `hermes-leo`), qui lisent des dizaines de `*_API_KEY`.

**Interdit comme raccourci pour exporter une seule clé.** Voir les pièges.

## Pièges

### 1. `env` explicite gagne sur `envFrom` — mais seulement pour les clés listées

Quand une clé existe dans `envFrom` **et** dans `env`, la valeur de `env` gagne.
C'est vrai et rassurant… mais l'inverse est le vrai danger :

> Une variable qui n'a qu'un **fallback dans le code** n'est pas protégée.
> Un fallback ne s'applique que si la variable est vide. `envFrom` la remplit.

Donc avant d'ajouter un `envFrom`, il faut lister **toutes** les variables que le
code lit avec un défaut, et vérifier qu'aucune n'existe dans le secret. Exemple de
ce qu'il faut aller chercher côté code :

```bash
grep -rn "os.Getenv\|envOr(" backend/       # Go
grep -n '\${[A-Z_]*:-'  entrypoint.sh       # shell : ${VAR:-defaut}
```

Cas concret rencontré : ajouter `envFrom` sur `assisted-teacher-secret` (path
`/agents/hermes-lya`) réinjecte `BIFROST_API_KEY`, que l'`entrypoint.sh` lit en
`${BIFROST_API_KEY:-}`. Le pod repasse alors en mode « envoie un header
Authorization » vers Bifrost, ce qui annulait un fix fait la veille. Aucune ligne
du diff ne le laissait voir.

### 2. Le nom de la variable — le lire dans la doc, jamais le déduire

Un nom plausible n'est pas un nom correct, et **deux outils qui font la même
chose n'utilisent pas forcément le même nom**. Pour une seule et même clé Brave
Search :

| Consommateur | Variable attendue | Source |
|---|---|---|
| `hermes-agent` (hermes-lya, hermes-leo) | `BRAVE_SEARCH_API_KEY` | [référence des variables d'environnement](https://hermes-agent.nousresearch.com/docs/reference/environment-variables) |
| skill `brave-search` de `pi` (assisted-teacher) | `BRAVE_API_KEY` | `search.js` → `process.env.BRAVE_API_KEY` ([badlogic/pi-skills](https://github.com/badlogic/pi-skills)) |

Une clé exportée sous un mauvais nom est un no-op silencieux : pas d'erreur, pas
de log, la fonctionnalité reste simplement absente.

Réflexe : trouver la variable dans la doc de l'outil **ou dans son code**, par
consommateur, puis prouver qu'elle est lue (log au boot, endpoint
d'introspection, commande de vérification du type `hermes setup`). Ne jamais
généraliser le nom trouvé pour un outil aux autres outils.

### 2 bis. Un nom, pas deux — c'est le composant non modifiable qui décide

Quand plusieurs consommateurs veulent la même valeur sous des noms différents, la
tentation est de dupliquer l'entrée dans Infisical, ou de renommer par pod avec
`secretKeyRef`. Les deux sont des dettes : deux entrées dérivent à la première
rotation, et un renommage par pod fait qu'aucune recherche `grep` ne retrouve
toute la chaîne.

**Choisir un seul nom, imposé par le consommateur qu'on ne peut pas modifier**, et
aligner le code qu'on possède.

Cas réel de la clé Brave :

| Consommateur | Nom attendu | Modifiable ? |
|---|---|---|
| `nousresearch/hermes-agent` (lya, leo) | `BRAVE_SEARCH_API_KEY` | non — image tierce |
| pi (assisted-teacher) | au choix | oui — notre code |

Donc `BRAVE_SEARCH_API_KEY` partout, et c'est l'extension pi qui lit ce nom. Une
seule entrée Infisical, aucun renommage, `grep -r BRAVE_SEARCH_API_KEY` retrouve
la chaîne complète de bout en bout.

Le renommage via `secretKeyRef` (`key` ≠ `name`) reste possible techniquement, mais
c'est une solution de dernier recours quand deux consommateurs non modifiables
imposent deux noms différents.

### 3. Exporter une clé ne suffit pas toujours à activer la fonctionnalité

Certains outils exigent en plus une sélection explicite en config. Hermès
n'auto-détecte le backend web *que si aucune sélection n'a jamais été écrite*, et
l'ordre d'auto-détection place Brave après Tavily / Exa / Parallel / Firecrawl /
SearXNG. Si une de ces clés traîne dans le secret, Brave ne sera jamais choisi.
D'où le pin explicite dans `config.yaml` :

```yaml
web:
  search_backend: "brave-free"
```

### 4. Les agents Hermès lisent aussi un `.env` sur leur PVC

`hermes-lya` / `hermes-leo` lisent l'environnement du process **et**
`<hermes home>/.env` (ici sur le PVC, `/opt/data/.env`). Une clé présente dans ce
fichier masque la valeur injectée par Kubernetes. C'est la cause d'un
`Invalid gateway API key` déjà vu sur `API_SERVER_KEY` : le secret K8s était bon,
le `.env` du PVC était périmé.

Si une clé fraîchement exportée ne prend pas effet, vérifier le `.env` avant de
soupçonner le secret.

### 5. `\n` en fin de clé

Les secrets Infisical portent souvent un newline final. Dans un header
`Authorization: Bearer <clé>\n`, le serveur répond une erreur trompeuse de type
« clé invalide ». Toujours trimmer côté application :

- Go : `strings.TrimSpace(os.Getenv("X"))`
- shell : `printf '%s' "$X" | tr -d '[:space:]'`

### 6. Noms de clés invalides

`envFrom` ignore silencieusement les clés qui ne sont pas des identifiants d'env
valides (tiret, point, espace) et émet un event `InvalidVariableNames`. Rester en
`UPPER_SNAKE_CASE`.

## Étape 3 — Vérifier

```bash
# la clé est-elle bien arrivée dans le secret K8s ?
kubectl -n <ns> get secret <secret> -o jsonpath='{.data}' | tr ',' '\n' | grep -i <clé>

# le conteneur la voit-il ? (longueur seulement, jamais la valeur en clair)
kubectl -n <ns> exec deploy/<deploy> -- sh -c 'echo ${#BRAVE_SEARCH_API_KEY}'

# quelles variables sont réellement injectées
kubectl -n <ns> get deploy <deploy> -o jsonpath='{.spec.template.spec.containers[0].envFrom}{"\n"}{.spec.template.spec.containers[0].env}'
```

Pour comparer deux composants censés porter la même clé sans l'exposer : logger
`len(clé)` + les 8 premiers hex d'un SHA-256. Non réversible, donc sûr en logs, et
suffisant pour prouver l'égalité.

## Étape 4 — Valider le manifest avant de pousser

```bash
kustomize build workloads/<service>/ > /dev/null && echo OK
```

## Rappel déploiement

Le cluster lit **`BaptTF/vps-infra`** (`repoURL` de chaque `Application` CR).
Merger sur un fork ne déploie rien. Vérifier sur quel remote on travaille avant
d'annoncer un déploiement.

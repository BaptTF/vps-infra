---
name: pool-watch
description: Surveillance quotidienne de la piscine via caméra Ring + Home Assistant. Capture un snapshot, analyse le niveau d'eau et la couleur, envoie un rapport photo dans le groupe "Nicole et Lea" sur Telegram.
user-invocable: true
---

# Pool Watch — Surveillance Piscine

Surveillance automatique quotidienne de la piscine Roquefort pendant les absences de René (vacances, déplacements).

## Quand utiliser ce skill

- René est absent et veut surveiller sa piscine à distance
- Vérification ponctuelle état piscine (`/pool-watch` ou "montre-moi la piscine")
- Pendant les vacances : cron quotidien automatique

## Prérequis

- Home Assistant accessible via API (`${HA_TOKEN}`)
- Plugin Ring-MQTT fonctionnel (addon `03cabcc9_ring_mqtt`)
- Caméra Ring "Chat" avec vue sur la piscine

## Entités Home Assistant

### Caméra
- **Snapshot** : `camera.chat_snapshot` (entité fiable, snapshot via MQTT)
- **Stream** : `camera.03cabcc9_ring_mqtt` (souvent unavailable, ne pas compter dessus)
- **⚠️ Toujours utiliser `camera.chat_snapshot`** — pas l'entité stream

### Capteurs piscine
- `input_number.derniere_temperature_piscine` — température eau (°C)
- `input_number.pourcentage_filtration_piscine` — % filtration
- `input_text.horaires_de_filtration_piscine` — horaires filtration
- `input_select.mode_filtration_piscine` — mode (Auto/Manuel)
- `input_text.calcul_filtration_piscine` — calcul auto (temp + durée)

## Workflow

### 1. Forcer un snapshot frais

**D'abord**, demander à la Ring de prendre une photo à la demande (ne dépend PAS de la détection de mouvement) :

```bash
curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" -H "Content-Type: application/json" \
  -d '{"entity_id": "button.chat_take_snapshot"}' \
  "https://harjullien.duckdns.org/api/services/button/press"
```

**Attendre 10 secondes** que le snapshot arrive via MQTT.

**Puis** télécharger l'image :

```bash
sleep 10 && curl -s -H "Authorization: Bearer ${HA_TOKEN}" \
  -o /home/node/.openclaw/media/pool-snapshot-$(date +%Y-%m-%d).jpg \
  "https://harjullien.duckdns.org/api/camera_proxy/camera.chat_snapshot"
```

### 2. Vérifier que c'est bien un JPEG

```python
f = open(path, 'rb')
assert f.read(2) == b'\xff\xd8', "Pas un JPEG valide"
```

Si le fichier est trop petit (<5KB) ou pas un JPEG → le snapshot a échoué. Retenter après 5 min.

### 3. Récupérer les données piscine

```bash
curl -s -H "Authorization: Bearer ${HA_TOKEN}" \
  "https://harjullien.duckdns.org/api/states/input_number.derniere_temperature_piscine"
```

Récupérer aussi : filtration %, horaires, mode.

### 4. Analyser l'image

Ouvrir l'image avec `read` et analyser visuellement :

**Checklist analyse :**
- [ ] **Niveau d'eau** : normal (au niveau skimmers), bas (sous skimmers), très bas, ou vide
- [ ] **Couleur de l'eau** : bleu clair (OK), vert (algues !), trouble (problème), marron (gros problème)
- [ ] **Débris** : feuilles, branches, objets flottants
- [ ] **Couverture** : bâche mise ou retirée
- [ ] **Alentours** : rien d'anormal autour de la piscine

**Seuils d'alerte :**
| Indicateur | Normal | Attention ⚠️ | Alerte 🚨 |
|-----------|--------|-------------|----------|
| Niveau | Skimmer | Légèrement bas | Très bas / vide |
| Couleur | Bleu clair | Légèrement verte | Vert foncé / trouble |
| Température | 10-28°C | <10°C ou >30°C | <5°C (gel !) |
| Filtration | Running | Durée réduite | Off / erreur |

### 5. Envoyer le rapport

```
message action=send channel=telegram target=-5162092129 filePath=<snapshot_path>
message="🏊 Rapport Piscine — [DATE]

📷 Snapshot Ring (heure capture)

🌡️ Eau : XX°C
⚙️ Filtration : XX% (mode Auto/Manuel)
🕐 Horaires : XXh-XXh

📊 Analyse :
✅ Niveau : [normal/bas/...]
✅ Couleur : [bleu/vert/...]
✅ Débris : [aucun/feuilles/...]
✅ Alentours : [RAS/...]

[🟢 Tout est OK / ⚠️ Attention / 🚨 Alerte]"
```

### 6. En cas d'alerte 🚨

Si problème détecté :
1. **Envoyer immédiatement** (ne pas attendre le rapport quotidien)
2. **Proposer des actions** : contacter un voisin ? Appeler le pisciniste ?
3. **Augmenter la fréquence** : passer à 2 snapshots/jour jusqu'à résolution

## Cron quotidien (vacances)

Programmer un cron pendant la durée d'absence :

```
cron add job={
  name: "pool-watch-daily",
  schedule: { kind: "cron", expr: "0 12 * * *", tz: "Europe/Paris" },
  payload: { kind: "agentTurn", message: "Exécute le skill pool-watch : capture un snapshot de la piscine via HA, analyse l'image, récupère la température et la filtration, et envoie le rapport photo + analyse dans le groupe Telegram 'Nicole et Lea' (target=-5162092129)." },
  sessionTarget: "isolated",
  delivery: { mode: "none" }
}
```

**⚠️ Activer/désactiver le cron selon les vacances de René :**
- Activer la veille du départ
- Désactiver au retour

## Commandes rapides

| Commande | Action |
|----------|--------|
| `/pool-watch` | Capture + analyse immédiate |
| `/pool-watch on` | Active le cron quotidien |
| `/pool-watch off` | Désactive le cron quotidien |
| `/pool-watch status` | Dernier rapport + état du cron |

## Règles

- **🚨 HA = PROD** : NE JAMAIS modifier les paramètres piscine (filtration, mode) sans autorisation EXPLICITE de René
- Surveillance = lecture seule (snapshot + capteurs)
- Photos stockées dans `/home/node/.openclaw/media/pool-snapshot-YYYY-MM-DD.jpg`
- Garder les 30 derniers snapshots, supprimer les plus vieux
- **Heure de capture** : 12h Paris (soleil au zénith, meilleure visibilité piscine)
- **Angle caméra de référence** : `workspace/pool-watch-reference-angle.jpg` (mis à jour 09/04/2026 — vue large piscine + terrasse + jardin, position validée par René)
- Si snapshot échoue → retenter à 12h, puis 14h. Si 3 échecs → alerter René

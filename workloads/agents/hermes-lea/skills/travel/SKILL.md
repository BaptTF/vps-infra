---
name: travel
description: "Framework de gestion de voyages BMAD - planification, réservations, hébergements, restaurants, analyse nuisances, teasers WhatsApp. Pour le voyage USA 2026. Commandes: /travel (dashboard), /travel:hotels, /travel:route, /travel:restaurants, /travel:bookings, /travel:teaser, /travel:calendar, /travel:brief, /travel:nuisance, /travel:validate"
user-invocable: true
---

# BMAD Travel - Gestion de Voyages

## Commandes

Quand l'utilisateur invoque `/travel` ou `/travel:xxx`, exécuter l'action correspondante.

### `/travel` (sans sous-commande) → Menu interactif + Dashboard

**Toujours** répondre avec un menu à boutons inline Telegram + résumé rapide :

```
message action=send channel=telegram target=974020023 message="🗺️ **Travel — USA 2026**\nJ-XX avant le départ !\n\nChoisis une commande :" buttons=[[{"callback_data":"/travel:hotels","text":"🏨 Hotels"},{"callback_data":"/travel:route","text":"🛣️ Route"}],[{"callback_data":"/travel:restaurants","text":"🍽️ Restaurants"},{"callback_data":"/travel:bookings","text":"📋 Bookings"}],[{"callback_data":"/travel:calendar","text":"📅 Calendar"},{"callback_data":"/travel:brief","text":"📝 Brief"}],[{"callback_data":"/travel:daily-brief","text":"📋 Brief Daily"},{"callback_data":"/travel:teaser","text":"🎯 Teaser"}],[{"callback_data":"/travel:admin","text":"🛂 Admin"},{"callback_data":"/travel:validate","text":"✅ Validate"}],[{"callback_data":"/travel:help","text":"❓ Help"}]]
```

Calculer J-XX depuis la date du jour jusqu'au 17 avril 2026. Puis répondre NO_REPLY (le message tool envoie déjà la réponse).

### Sous-commandes

| Commande | Action |
|----------|--------|
| `/travel:hotels` | Afficher `hotels.md` — tableau de tous les hébergements |
| `/travel:route` | Afficher `route-plan.md` — itinéraire jour par jour |
| `/travel:restaurants` | Afficher `restaurants.md` — options restos par ville |
| `/travel:bookings` | Lister les fichiers `bookings/*.yaml` et résumer chaque réservation |
| `/travel:teaser` | Générer un teaser WhatsApp → lire [references/teaser-guide.md](references/teaser-guide.md) |
| `/travel:calendar` | Sync Google Calendar ↔ bookings — vérifier cohérence |
| `/travel:brief` | Afficher `trip-brief.md` — vue d'ensemble complète |
| `/travel:daily-brief` | Générer le brief quotidien d'un jour → skill `bmad-travel/skills/daily-brief.md` |
| `/travel:nuisance` | Analyse nuisances pour un hébergement → lire [references/nuisance-check.md](references/nuisance-check.md) |
| `/travel:validate` | Validation complète : croiser hotels.md, bookings/, calendar, route-plan |
| `/travel:admin` | Check formalités admin par pays → lire [references/admin-check.md](references/admin-check.md) |
| `/travel:help` | Afficher l'aide détaillée ci-dessous |

### `/travel:help` → Aide détaillée

Envoyer ce message :

```
🗺️ **Travel Help — USA 2026**

🏨 **Hotels** — Tableau complet des 18 nuits : nom, ville, prix, statut, n° de confirmation. Source : hotels.md

🛣️ **Route** — Itinéraire jour par jour avec distances, temps de route, étapes clés et horaires. Source : route-plan.md

🍽️ **Restaurants** — Sélection de restaurants par ville/étape (pas de chaînes !). Budget max 65€/pers. Source : restaurants.md

📋 **Bookings** — Détail complet de chaque réservation : n° confirmation, prix, politique annulation, contacts. Source : bookings/*.yaml

📅 **Calendar** — Vérifie que Google Calendar est synchro avec tous les bookings. Détecte les manquants et incohérences.

📝 **Brief** — Vue d'ensemble du voyage : voyageurs, phases, dates, contraintes, budget global. Source : trip-brief.md

📋 **Brief Daily** — Génère le brief quotidien d'un jour (full + minimal + WhatsApp). Révèle les teasers mystères ! Usage : `/travel:daily-brief 3` ou `/travel:daily-brief demain`

🎯 **Teaser** — Génère et envoie un teaser mystère au groupe WhatsApp USA-Vegas 2026. Max 1/semaine, sans spoiler !

✅ **Validate** — Validation croisée complète : compare hotels.md ↔ bookings/ ↔ calendar ↔ route-plan. Détecte toute incohérence.

🛂 **Admin** — Check formalités administratives par pays et par voyageur. Passeport, ESTA, AVE, MPC, ArriveCAN, assurance, permis... Vérifie dans les emails et le calendrier. Statut ✅/⚠️/❌.

🔍 **Nuisance** — Analyse les nuisances d'un hébergement (bruit, propreté, sécurité, accès) avant réservation. Verdict : ✅/🟡/🔴
```

## Voyage actif

**USA 2026 - Google Cloud Next + Montréal**
- Dates : 17 avril → 6 mai 2026
- Base : `/home/node/.config/travel/trips/2026-usa-google-next/`

## Fichiers clés

| Fichier | Chemin relatif (depuis base) |
|---------|------------------------------|
| Vue d'ensemble | `trip-brief.md` |
| Hébergements | `hotels.md` |
| Itinéraire | `route-plan.md` |
| Restaurants | `restaurants.md` |
| Réservations | `bookings/*.yaml` |
| Activités | `activities.yaml` |
| Teasers | `briefs/teasers/` |

## Règles

- **Vérifier distances** avec recherche web (les LLMs inventent !)
- **Budget** : max 200€/nuit groupe, 65€/pers resto
- **Pas de chaînes** : Éviter Applebee's, Olive Garden, etc.
- **Max 4h route/jour** et 1 parc majeur/jour
- **WhatsApp groupe** : USA-Vegas 2026 (`120363407054932815@g.us`)
- **Git** : après toute modification → `cd /home/node/.config/travel && git add -A && git commit -m "msg" && git push`

## Calendrier Google

- Accès via `mcporter call mcp-gsuite.get_calendar_events` / `create_calendar_event` / `delete_calendar_event`
- **User ID** : `rene.jullien@gmail.com` (paramètre `__user_id__`)
- **Pas d'update** : supprimer + recréer pour modifier un event
- **Format summary** : `🏨 [Ville] - [Hôtel] ([N pers]) - [Prix]`
- **Inviter Laurine** : `laurine.rolland83400@gmail.com` (son email Google Calendar)

## Analyse nuisances

Pour les détails, lire [references/nuisance-check.md](references/nuisance-check.md).

Niveaux : ✅ RAS | 🟡 Attention | 🔴 Éviter

## Voyageurs

| Phase | Qui | Dates |
|-------|-----|-------|
| Phase 1 (5 pers) | René, Nicole, Alexandre, Dinah, Laurine | 17-27 avril |
| Phase 2 (4 pers) | René, Nicole, Alexandre, Dinah | 27 avril - 1 mai |
| Phase 3 (3 pers) | René, Nicole, Baptiste | 1-5 mai (Montréal) |

---
name: teaser
description: Génère un teaser hebdomadaire excitant pour le groupe WhatsApp voyage - la "pub de la semaine" qui fait rêver sans spoiler. Pour le voyage USA 2026.
user-invocable: true
---

# Teaser Brief Generator

Génère des teasers hebdomadaires envoyés au groupe WhatsApp voyage pour créer l'excitation.

## Quand utiliser ce skill

Utiliser quand René demande :
- Teaser pour le groupe voyage
- Message excitant pour les participants
- Update hebdo du voyage

## Usage

```
/teaser           → Génère le prochain teaser
/teaser 3         → Génère le teaser #3
/teaser status    → Voir l'historique des teasers envoyés
```

## Philosophie

"Donner envie, montrer que ça avance, sans tout révéler"

- ✅ Créer l'excitation
- ✅ Montrer l'avancement (confiance)
- ✅ Teaser sans spoiler
- ❌ Ne pas tout révéler

## Sources

- `trip-brief.md` - Dates, vision
- `hotels.md` - Status réservations
- `bookings/*.yaml` - Confirmations
- `briefs/teasers/teaser-history.yaml` - **CRITIQUE : éviter les redites**

## Anti-Redite

**TOUJOURS lire `teaser-history.yaml` avant de générer !**
- Ne pas répéter les accomplissements déjà mentionnés
- Varier les sneak peeks
- Nouveau chiffre à chaque teaser
- Nouveau fun fact à chaque teaser

## Structure du Teaser (COMPLÈTE - OBLIGATOIRE)

```
🌟 *USA 2026 - TEASER #[N]* 🌟
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📅 *J-[XX] avant le départ !*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔥 *CE QU'ON A BOUCLÉ*
✅ [Accomplissement 1]
✅ [Accomplissement 2]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✨ *SNEAK PEEK*
🏜️ [Description mystère lieu 1]
🌅 [Description mystère lieu 2]

💭 _"[Citation évocatrice ou fun fact]"_
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🌡️ *MÉTÉO LIVE*
☀️ Là-bas aujourd'hui : *XX°C*
   (pendant qu'on se gèle ici... 😎)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 *STATUT*
🟢 Vols : X/X
🟢 Activités : X/X
🟡 Hôtels : en cours
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📚 *LE SAVIEZ-VOUS ?*
[Fait historique/géologique/culturel en 3-5 lignes]
[Extrait de faits_educatifs dans teaser-history.yaml]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💡 *LE CHIFFRE*
🚗 *[XXXX]* [contexte du chiffre]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎯 *PROCHAINE ÉTAPE*
→ [Action clé à venir]
→ [Date importante]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🗓️ _Prochain teaser : [date]_

🚀 *[Slogan fun]*
```

## Techniques de Teasing

| Lieu réel | Teaser mystère |
|-----------|----------------|
| Grand Canyon | "Un trou si grand qu'on voit la courbure de la Terre" |
| Antelope Canyon | "Des murs qui dansent avec la lumière" |
| Horseshoe Bend | "Une rivière qui a décidé de faire demi-tour" |
| Bryce Canyon | "Une armée de géants pétrifiés" |

## 🌡️ Météo Live (OBLIGATOIRE)

**Chaque teaser DOIT inclure un "clin d'œil météo" !**

Récupérer la météo du jour d'envoi pour UN lieu teasé (sans le nommer) :

```bash
# Exemple Chloride (35.4161, -114.2019)
curl -s "https://api.open-meteo.com/v1/forecast?latitude=35.4161&longitude=-114.2019&daily=temperature_2m_max&timezone=America/Los_Angeles&forecast_days=1"
```

**Format dans le teaser :**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🌡️ *MÉTÉO LIVE*
☀️ Là-bas aujourd'hui : *22°C*
   (ici on se les gèle, eux non 😎)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Coordonnées des lieux :**
| Lieu | Lat | Lon |
|------|-----|-----|
| Las Vegas | 36.1699 | -115.1398 |
| Chloride | 35.4161 | -114.2019 |
| Grand Canyon | 36.0544 | -112.1401 |
| Page | 36.9147 | -111.4558 |
| Zion | 37.2982 | -113.0263 |
| Bryce | 37.5930 | -112.1871 |
| Moab | 38.5733 | -109.5498 |
| Denver | 39.7392 | -104.9903 |

**Effet recherché :** Rendre le voyage RÉEL et tangible. "C'est pas juste un plan, c'est un endroit qui existe maintenant, avec sa météo."

## Règles

- ✅ Émojis généreusement
- ✅ Compte à rebours J-XX
- ✅ UN chiffre marquant par teaser
- ❌ Pas de liens (WhatsApp prévisualise = spoiler)
- ❌ Max 15-20 lignes

## 🛒 Rappels achats (J-30 à J-15)

**À partir de J-30 et jusqu'à J-15**, inclure dans la section NEXT/PROCHAINE ÉTAPE un rappel des achats à faire avant le départ. Objectif : laisser le temps de commander sur Amazon/en magasin.

**Exemples d'items à rappeler :**
- 🔌 Adaptateur prise (selon pays de destination)
- 🧊 Glacière souple pliable (si road trip + courses)
- 💧 Gourdes / bouteilles (si randonnée/climat sec)
- 🧴 Crème solaire haute protection (si destination ensoleillée)
- 🔋 Batterie externe (si long trajets/randos sans prises)
- 🥾 Chaussures de randonnée (si prévu, ACHETER TÔT pour les faire)

**Règle :** Lire la checklist valise du Day 0 et identifier les items qui ne sont pas "standards" (= pas dans toutes les maisons). Les rappeler dans les teasers J-30 à J-15 pour laisser le temps aux voyageurs de se les procurer.

## 🧳 Spécial Valise (J-10, message séparé)

**À J-10 (ou J-9), envoyer un message DÉDIÉ valise** en complément de la news classique.

**Format : 2 messages séparés**
1. News classique (hôtel, éducatif, chiffre, météo)
2. Message "🧳 SPÉCIAL VALISE" avec listes personnalisées par groupe

**Comment générer :**
1. Récupérer la météo historique (Open-Meteo archive API) pour chaque étape
2. Catégoriser : 🔥 Chaud (25°C+) / 🌤️ Doux (18-24°C) / 🥶 Froid (<18°C)
3. Générer 1 liste par groupe de voyageurs (selon les phases/durées)
4. Indiquer X jours chauds / Y doux / Z froids + recommandations valise
5. Ajouter checklist commune + vérifications critiques

**Fichier :** `teaser-{NN}b-valise-{date}.whatsapp.txt`

## Groupe WhatsApp

USA-Vegas 2026 : `120363407054932815@g.us`

## Workflow Complet (OBLIGATOIRE)

### AVANT de générer

1. **git pull** `/home/node/.config/travel`
2. **Lire teaser-history.yaml** - CRITIQUE pour éviter les redites
3. **Lire TOUS les teasers précédents** dans `briefs/teasers/teaser-*.whatsapp.txt`
4. **Vérifier si le fichier du teaser existe déjà** :
   - SI EXISTE → Le relire, corriger/améliorer, NE PAS tout virer
   - SI N'EXISTE PAS → Générer depuis zéro
5. **Vérifier les VRAIS statuts** dans hotels.md, bookings/*.yaml
6. **Récupérer météo live** du jour d'envoi (API open-meteo)

### Règles anti-redite

→ Voir la checklist complète dans l'agent source.

### APRÈS validation René

1. **Envoyer** au groupe WhatsApp `120363407054932815@g.us`
2. **Sauvegarder** le fichier :
   ```
   /home/node/.config/travel/trips/2026-usa-google-next/briefs/teasers/teaser-XX-YYYY-MM-DD.whatsapp.txt
   ```
3. **Mettre à jour** `teaser-history.yaml` (voir checklist post-envoi dans l'agent source)
4. **Commit/push** les changements

## Agent source (SOURCE DE VÉRITÉ)

**TOUJOURS lire ce fichier pour les règles complètes, la checklist conformité, anti-redite et post-envoi :**

`/home/node/.config/travel/bmad-travel/agents/teaser-brief.md`

Ce SKILL.md est un wrapper léger. Les règles détaillées, la structure du template, les checks de conformité et anti-redite sont maintenus dans l'agent source ci-dessus pour être partagés avec Claude Code.

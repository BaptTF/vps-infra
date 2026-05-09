---
name: nicole-digest
description: Génère un digest quotidien des emails importants pour Nicole, envoyé via WhatsApp. Promos (Intermarché, Nespresso), finance, mails importants. Tourne après le check emails quotidien (19h). Commande /nicole-digest ou invocation automatique post email-check.
---

# Nicole Digest — Résumé Email Quotidien

Digest quotidien des emails de René, filtré et résumé pour Nicole via WhatsApp.

## Déclenchement

- **Automatique :** Après le check emails quotidien (19h heure française)
- **Manuel :** Sur demande (`/nicole-digest`, "fais le digest pour Nicole", etc.)

## Workflow

### 1. SCANNER LES EMAILS DU JOUR

```bash
himalaya envelope list --account gmail --page-size 30
```

Filtrer les emails reçus **depuis le dernier digest** (dernières ~24h).

### 2. CATÉGORISER PAR INTÉRÊT

Classer chaque email dans les catégories Nicole :

| Catégorie | Icône | Critères |
|-----------|-------|----------|
| **Promos gardées** | 🛒☕ | Intermarché, Nespresso uniquement |
| **Finance** | 💰 | Banque, assurance, factures, impôts, mutuelle, énergie |
| **Important** | 📌 | Famille, école, médical, administratif, voyage, réservations |
| **À signaler** | ⚠️ | Urgences, deadlines proches, actions requises |

**EXCLUSIONS actuelles :** Aucune (à affiner progressivement avec René).

### 3. EXTRAIRE LE CONTENU PERTINENT

Pour chaque email retenu, lire le contenu :
```bash
himalaya message read --account gmail <ID>
```

Extraire :
- **Promos :** Offre principale, montant/%, dates validité, code promo si présent
- **Finance :** Montant, échéance, action requise
- **Important :** Résumé 1-2 lignes, action requise si applicable

### 4. RÉDIGER LE DIGEST

**Format WhatsApp — Ton Léa, concis et utile :**

```
☀️ *Digest du [jour] [date]* ☀️

🛒 *Promos*
• Intermarché : [résumé promo] (jusqu'au [date])
• Nespresso : [résumé offre]

💰 *Finance*
• [Expéditeur] : [résumé] — [action si nécessaire]

📌 *Important*
• [Sujet] : [résumé court]

💤 *RAS* (si aucune catégorie n'a de contenu)

Bonne soirée ! 😘
— Léa
```

**Règles de rédaction :**
- Max 15-20 lignes total (Nicole préfère court)
- Pas de jargon technique
- Prix/montants toujours en gras
- Dates de validité promos systématiques
- Si rien d'intéressant dans une catégorie → l'omettre (pas de section vide)
- Si AUCUN email pertinent → envoyer quand même un petit "RAS aujourd'hui 😴"

### 5. ENVOYER VIA WHATSAPP

Envoyer en DM à Nicole (pas dans un groupe) :

```
message action=send channel=whatsapp target="33662809538@s.whatsapp.net" message="[digest]"
```

**⚠️ TIMEZONE :** Nicole est en Europe/Paris. Le digest part à ~19h heure française (18h UTC en hiver, 17h UTC en été). Ne JAMAIS envoyer entre 22h et 8h heure de Nice.

### 6. DOCUMENTER

Ajouter une ligne dans la mémoire du jour :
```
- ✅ Nicole digest envoyé : [N] emails résumés ([catégories])
```

## Personnalisation progressive

Ce skill s'affine avec le temps. René ajuste les filtres :
- Voir `references/filters.md` pour les règles de filtrage actuelles
- Ajouter/retirer des catégories selon feedback Nicole et René
- Nouveaux expéditeurs "gardés" → mettre à jour filters.md

## Promos surveillées (newsletters gardées)

| Newsletter | Quoi surveiller |
|-----------|----------------|
| **Intermarché** 🛒 | Promos semaine, e-coupons, défis, solde fidélité |
| **Nespresso** ☕ | Offres capsules, machine à 1€, éditions limitées, programme fidélité |

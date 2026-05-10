---
name: email-check
description: Workflow pour vérifier les emails et mettre à jour les fichiers voyage + calendrier. Extraction de confirmations, prix, dates et mise à jour automatique des bookings YAML, hotels.md et Google Calendar.
user-invocable: true
---

# Skill: Email Check Voyage

Workflow pour vérifier les emails et mettre à jour les fichiers voyage + calendrier.

## Quand utiliser

- Revue quotidienne emails (heartbeat 19h)
- Sur demande explicite ("check mes emails voyage")
- Après réception notification de réservation

## Workflow complet

### 1. LISTER LES EMAILS RÉCENTS

```bash
himalaya envelope list --page-size 20
```

**Filtrer les emails pertinents :**
- ✅ Confirmations : Airbnb, Booking, Hotels.com, HotelsOne, compagnies aériennes
- ✅ Factures/paiements : récapitulatifs, factures, confirmations paiement
- ✅ Loteries/réservations : résultats Denver Mint, Antelope Canyon, etc.
- ❌ Ignorer : Promos marketing, suggestions, newsletters

### 2. LIRE CHAQUE EMAIL PERTINENT

```bash
himalaya message read <ID>
```

**Extraire les infos clés :**
- N° de confirmation / réservation
- Dates check-in / check-out exactes
- Prix total (avec détail taxes si dispo)
- Politique d'annulation (deadline, pénalités)
- Téléphone / adresse exacte
- Paiements : montant payé vs reste à payer

### 3. METTRE À JOUR LES FICHIERS BOOKING

**Chemin :** `/home/node/.config/travel/trips/2026-usa-google-next/bookings/`

**Format fichier hotel-XXX.yaml :**
```yaml
# [Nom Hôtel] - [Ville]
# Nuit X - [Date]
# Source: Email [Platform] [Date]

booking:
  type: hotel
  status: CONFIRMED
  confirmation_[platform]: "NUMERO"
  booked_via: [Platform]
  booked_date: "YYYY-MM-DD"

property:
  name: "[Nom]"
  address: "[Adresse complète]"
  phone: "[Tel avec indicatif]"

stay:
  checkin: "YYYY-MM-DD HH:MM"
  checkout: "YYYY-MM-DD HH:MM"
  nights: N

room:
  type: "[Type chambre]"
  beds: "[Config lits]"

guests:
  total: N
  names: [liste]

pricing:
  currency: [USD/EUR]
  subtotal: XX.XX
  taxes: XX.XX
  total: XX.XX
  payment_location: "prepaid" | "at hotel"

cancellation:
  policy: "refundable" | "non-refundable"
  deadline: "YYYY-MM-DD HH:MM"
  penalty: "[Description]"

included:
  - "[Service 1]"
  - "[Service 2]"
```

**Aussi mettre à jour `hotels.md`** avec les infos clés dans le tableau.

### 4. CRÉER/METTRE À JOUR ÉVÉNEMENT CALENDRIER

```bash
mcporter call mcp-gsuite create_calendar_event --args '{
  "__user_id__": "rene.jullien@gmail.com",
  "summary": "🏨 [Ville] - [Hôtel] ([N pers]) - [Prix]",
  "start_time": "YYYY-MM-DDTHH:MM:00",
  "end_time": "YYYY-MM-DDTHH:MM:00",
  "description": "Conf: [N°]\n[Détails chambre]\n[Politique annulation]",
  "location": "[Adresse complète]"
}'
```

**Format summary :** `🏨 [Ville] - [Nom court] ([N] pers) - [Prix€/$]`

**Description inclure :**
- N° confirmation
- Type chambre / config
- Services inclus (petit-dej, parking, WiFi)
- Deadline annulation si applicable

### 5. COMMIT & PUSH

```bash
cd /home/node/.config/travel
git add -A
git commit -m "📋 [Hôtel]: [résumé des changements]"
git push origin main
```

### 6. DOCUMENTER DANS MÉMOIRE

Mettre à jour `/home/node/.openclaw/lea/workspace/memory/YYYY-MM-DD.md` avec :
- Emails traités
- Actions effectuées
- Infos nouvelles extraites

## Checklist par type d'email

### ✅ Confirmation hôtel
- [ ] N° confirmation extrait
- [ ] Prix total + détail taxes
- [ ] Dates/heures check-in/out
- [ ] Téléphone hôtel
- [ ] Politique annulation
- [ ] Fichier booking YAML créé/màj
- [ ] hotels.md mis à jour
- [ ] Événement calendrier créé

### ✅ Confirmation vol
- [ ] N° réservation / PNR
- [ ] Horaires exacts
- [ ] Terminal / porte si dispo
- [ ] Bagages inclus
- [ ] Fichier vols-XXX.yaml màj
- [ ] Événement calendrier créé

### ✅ Confirmation activité
- [ ] N° réservation
- [ ] Horaire exact
- [ ] Point de RDV / adresse
- [ ] Instructions spéciales
- [ ] Fichier activities-XXX.yaml màj
- [ ] Événement calendrier créé

### ✅ Facture / Paiement
- [ ] Montant payé
- [ ] Reste à payer
- [ ] Date prélèvement prévu
- [ ] Fichier booking concerné màj

## Hôtels manquant des infos (à compléter)

| Hôtel | Manque | Action |
|-------|--------|--------|
| Chloride (Shep's) | N° confirmation Airbnb | Retrouver dans app/emails janvier |
| Page (Julie) | N° confirmation Airbnb | Retrouver dans app/emails janvier |

## Notes

- **Timezone :** Les heures locales US sont en UTC-7 (Mountain) ou UTC-8 (Pacific)
- **Prix :** Toujours noter devise + conversion estimée
- **Annulation :** Mettre en évidence les deadlines proches

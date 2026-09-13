# Formalités admin / apps d'entrée (Travel)

Quand `/travel:admin` ou création/maj d'un seed TripKit avec **vol hors France**.

## Règle

Pour **chaque pays d'entrée** (aller, escale immigration) :

1. Chercher l'**autorisation** numérique (ESTA, AVE/eTA Canada, UK ETA…).
2. Chercher l'**app / déclaration d'arrivée** (MPC USA, ArriveCAN *si encore
   requis*, Visit Japan Web, NZ Traveller Declaration…).
3. Confirmer sur le **site officiel** (ne pas inventer une app obsolète).
4. Reporter dans TripKit :
   - `avant-de-partir-*` : obtenir / vérifier
   - packing Documents & Tech : autorisation + app téléphone
5. Day 0 : rappel docs.

## Source de vérité seeds

Lire et suivre :

- `rjullien/tripkit-seeds/skills/tripkit-entry-apps/SKILL.md`
- `SEED-GUIDE.md` § Formalités numériques
- `seed-qa.py` warnings `destination … détectée`

## Exemples (vérifier à jour)

| Pays | Autorisation | App typique |
|------|--------------|-------------|
| Canada | AVE / eTA | ArriveCAN souvent plus requis |
| USA | ESTA | Mobile Passport Control (MPC) |
| UK | UK ETA | — |
| Japon | — | Visit Japan Web |

UE/Schengen pour voyageur FR : en général **rien** d'ESTA/AVE.

# OpenStreetMap — Geographic Search & Routing

## Description
Search locations, geocode, calculate routes using OpenStreetMap APIs.
Replaces the osm-mcp-server.

## When to Use
- Search for a place/address (geocoding)
- Get coordinates for a location
- Calculate distance or route between places
- Find nearby POIs (restaurants, hotels, etc.)

## Endpoints

### Nominatim — Geocoding
```bash
# Search for a place
curl -s "https://nominatim.openstreetmap.org/search?q=Tour+Eiffel+Paris&format=json&limit=3" \
  -H "User-Agent: NullClaw-Lea/1.0" | jq '.[] | {name: .display_name, lat, lon}'

# Reverse geocoding
curl -s "https://nominatim.openstreetmap.org/reverse?lat=43.7102&lon=7.2620&format=json" \
  -H "User-Agent: NullClaw-Lea/1.0" | jq '{address: .display_name, details: .address}'
```

### Overpass — POI Search
```bash
# Find restaurants within 500m
curl -s "https://overpass-api.de/api/interpreter" \
  --data-urlencode 'data=[out:json];node["amenity"="restaurant"](around:500,43.7102,7.2620);out body;' \
  | jq '.elements[:5] | .[] | {name: .tags.name, cuisine: .tags.cuisine, lat, lon}'
```

### OSRM — Routing
```bash
# Route between two points (lon,lat!)
curl -s "https://router.project-osrm.org/route/v1/driving/7.2620,43.7102;2.3522,48.8566?overview=false" \
  | jq '{distance_km: (.routes[0].distance/1000 | round), duration_min: (.routes[0].duration/60 | round)}'
```

## Rate Limits
- Nominatim: max 1 req/s, include User-Agent
- OSRM: public demo server, not for heavy use
- OSRM uses **lon,lat** order (not lat,lon!)

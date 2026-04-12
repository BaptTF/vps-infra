---
name: weather-api
description: Météo via OpenWeatherMap API - conditions actuelles et prévisions. Utilisable pour le voyage USA, teasers, ou toute question météo.
user-invocable: true
---

# Weather API Skill - OpenWeatherMap

## Setup Instructions

### 1. Get API Key
1. Go to: https://home.openweathermap.org/users/sign_up
2. Create free account
3. Get API key from dashboard
4. Store it: `export OPENWEATHER_API_KEY="your_key"`

### 2. Les Saisies Coordinates
- **Latitude:** 45.7587
- **Longitude:** 6.5404
- **Location:** Les Saisies, Savoie, France

### 3. API Endpoints
- **Current:** `https://api.openweathermap.org/data/2.5/weather?lat={lat}&lon={lon}&appid={API_key}&units=metric&lang=fr`
- **Forecast:** `https://api.openweathermap.org/data/2.5/forecast?lat={lat}&lon={lon}&appid={API_key}&units=metric&lang=fr`
- **One Call:** `https://api.openweathermap.org/data/3.0/onecall?lat={lat}&lon={lon}&appid={API_key}&units=metric&lang=fr`

### 4. Usage Examples
```bash
# Current weather
curl "https://api.openweathermap.org/data/2.5/weather?lat=45.7587&lon=6.5404&appid=${OPENWEATHER_API_KEY}&units=metric&lang=fr"

# 5-day forecast (3h intervals)
curl "https://api.openweathermap.org/data/2.5/forecast?lat=45.7587&lon=6.5404&appid=${OPENWEATHER_API_KEY}&units=metric&lang=fr"
```

### 5. Data Structure
- **Current:** temp, feels_like, humidity, pressure, wind, clouds, visibility, weather description
- **Forecast:** 40 entries (5 days × 8 periods/day), same fields + timestamp
- **Alerts:** Government weather warnings when available

## Commands
- `weather_current()` - Current conditions Les Saisies
- `weather_forecast(hours=24)` - Forecast next X hours
- `weather_alerts()` - Active weather warnings
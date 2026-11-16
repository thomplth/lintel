const conditions = [
  [[0], 'Clear', 'sun.max.fill'], [[1, 2], 'Partly cloudy', 'cloud.sun.fill'], [[3], 'Overcast', 'cloud.fill'],
  [[45, 48], 'Fog', 'cloud.fog.fill'], [[51, 53, 55, 56, 57], 'Drizzle', 'cloud.drizzle.fill'],
  [[61, 63, 65, 66, 67, 80, 81, 82], 'Rain', 'cloud.rain.fill'], [[71, 73, 75, 77, 85, 86], 'Snow', 'cloud.snow.fill'],
  [[95, 96, 99], 'Thunderstorm', 'cloud.bolt.rain.fill'],
];

function describe(code) {
  const match = conditions.find((entry) => entry[0].indexOf(code) >= 0);
  return match ? { label: match[1], symbol: match[2] } : { label: 'Unknown', symbol: 'cloud.fill' };
}

let latest = null, failure = null, loadedAt = 0;

async function load(host) {
  if (latest && Date.now() - loadedAt < 10 * 60 * 1000) return;
  try {
    let place = host.storage.get('place', null);
    if (!place) {
      const guess = Intl.DateTimeFormat().resolvedOptions().timeZone.split('/').pop().replace(/_/g, ' ');
      place = await find(host, guess);
    }
    const query = `latitude=${place.latitude}&longitude=${place.longitude}&timezone=auto&forecast_days=5`
      + '&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code'
      + '&hourly=temperature_2m&daily=weather_code,temperature_2m_max,temperature_2m_min';
    latest = { place, forecast: await host.fetchJSON(`https://api.open-meteo.com/v1/forecast?${query}`) };
    failure = null;
    loadedAt = Date.now();
  } catch (error) {
    failure = error.message;
  }
}

async function find(host, name) {
  const found = await host.fetchJSON(`https://geocoding-api.open-meteo.com/v1/search?count=1&name=${encodeURIComponent(name)}`);
  if (!found.results || found.results.length === 0) throw new Error(`No place called ${name}`);
  const place = { name: found.results[0].name, latitude: found.results[0].latitude, longitude: found.results[0].longitude };
  host.storage.set('place', place);
  return place;
}

defineModule({
  meta: {
    id: 'weather',
    title: 'Weather',
    icon: 'cloud.sun.fill',
    summary: 'Current temperature in the bar; today and the next days in the panel.',
    pinned: false,
    order: 35,
    refreshSeconds: 600,
    permissions: ['api.open-meteo.com', 'geocoding-api.open-meteo.com'],
  },
  async render(host) {
    await load(host);
    if (!latest) return row([icon('cloud.fill', { tone: 'secondary' }), text('—', { tone: 'secondary' })]);
    const current = latest.forecast.current;
    return row([icon(describe(current.weather_code).symbol), text(`${Math.round(current.temperature_2m)}°`, { mono: true })]);
  },
  async panel(host) {
    await load(host);
    const search = field('Change place', 'setPlace', { icon: 'magnifyingglass', submitLabel: 'Find' });
    if (!latest) {
      return [empty('wifi.slash', 'Weather is unavailable', { message: failure || 'Still loading.', action: 'retry' }), search];
    }
    const forecast = latest.forecast, current = forecast.current, daily = forecast.daily;
    const now = describe(current.weather_code);
    const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return [
      grid(2, [
        stat(latest.place.name, Math.round(current.temperature_2m), { unit: '°C', icon: now.symbol, caption: now.label }),
        stat('Feels like', Math.round(current.apparent_temperature), { unit: '°C', caption: `Humidity ${current.relative_humidity_2m}%` }),
      ]),
      section('Next 24 hours', [
        chart(forecast.hourly.temperature_2m.slice(0, 24), { kind: 'line', height: 'small', labels: ['now', '+12 h', '+24 h'] }),
        keyValue('Wind', `${Math.round(current.wind_speed_10m)} km/h`, { mono: true }),
      ]),
      section('Days ahead', [
        list(daily.time.slice(0, 5).map((day, index) => item(index === 0 ? 'Today' : weekdays[new Date(day).getDay()], {
          icon: describe(daily.weather_code[index]).symbol,
          subtitle: describe(daily.weather_code[index]).label,
          value: `${Math.round(daily.temperature_2m_min[index])}° / ${Math.round(daily.temperature_2m_max[index])}°`,
        }))),
      ]),
      search,
      failure ? note(`Showing the last good reading. ${failure}`, { tone: 'warn' }) : note(`Updated ${host.format.ago(loadedAt)} · Open-Meteo`),
    ];
  },
  actions: {
    async setPlace(host, name) {
      try {
        await find(host, name);
        latest = null;
        loadedAt = 0;
      } catch (error) {
        failure = error.message;
      }
    },
    retry() {
      loadedAt = 0;
    },
  },
});

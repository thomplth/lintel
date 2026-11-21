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

const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function forecastList(daily, compact) {
  return list(daily.time.slice(0, 5).map((day, index) => item(index === 0 ? 'Today' : weekdays[new Date(day).getDay()], {
    icon: describe(daily.weather_code[index]).symbol,
    subtitle: describe(daily.weather_code[index]).label,
    value: `${Math.round(daily.temperature_2m_min[index])}° / ${Math.round(daily.temperature_2m_max[index])}°`,
  })), { compact });
}

function unavailable() {
  return [empty('wifi.slash', 'Weather is unavailable', { message: failure || 'Still loading.', action: 'retry' })];
}

defineModule({
  meta: {
    id: 'weather',
    title: 'Weather',
    icon: 'cloud.sun.fill',
    summary: 'Current temperature in the bar; hourly trend and 5-day forecast across widget sizes.',
    pinned: false,
    order: 35,
    refreshSeconds: 600,
    sizes: ['chip', 'small', 'wide', 'medium', 'large'],
    defaultSize: 'medium',
    permissions: ['api.open-meteo.com', 'geocoding-api.open-meteo.com'],
  },
  views: {
    async chip(host) {
      await load(host);
      if (!latest) return row([icon('cloud.fill', { tone: 'secondary' }), text('—', { tone: 'secondary' })]);
      const current = latest.forecast.current;
      return row([icon(describe(current.weather_code).symbol), text(`${Math.round(current.temperature_2m)}°`, { mono: true })]);
    },
    async small(host) {
      await load(host);
      if (!latest) return unavailable();
      const { current, daily } = latest.forecast;
      const now = describe(current.weather_code);
      return [
        column([
          row([text(latest.place.name, { role: 'label', weight: 'medium' }), spacer(), icon(now.symbol, { tone: 'accent' })]),
          text(`${Math.round(current.temperature_2m)}°`, { role: 'display', mono: true }),
          text(now.label, { role: 'label' }),
          spacer(),
          text(`L ${Math.round(daily.temperature_2m_min[0])}° · H ${Math.round(daily.temperature_2m_max[0])}°`, { role: 'caption', mono: true, tone: 'tertiary' }),
        ], { spacing: 'tight' }),
      ];
    },
    async wide(host) {
      await load(host);
      if (!latest) return unavailable();
      const forecast = latest.forecast, current = forecast.current;
      const now = describe(current.weather_code);
      return [
        split([
          stat(latest.place.name, Math.round(current.temperature_2m), {
            unit: '°C', icon: now.symbol, caption: `${now.label} · Feels ${Math.round(current.apparent_temperature)}°`,
          }),
          section('Next 24 hours', [
            chart(forecast.hourly.temperature_2m.slice(0, 24), { kind: 'line' }),
          ]),
        ], { weights: [1, 1.3] }),
      ];
    },
    async medium(host) {
      await load(host);
      if (!latest) return unavailable();
      const forecast = latest.forecast, current = forecast.current, daily = forecast.daily;
      const now = describe(current.weather_code);
      return [
        grid(2, [
          stat(latest.place.name, Math.round(current.temperature_2m), { unit: '°C', icon: now.symbol, caption: now.label }),
          stat('Feels like', Math.round(current.apparent_temperature), { unit: '°C', caption: `Humidity ${current.relative_humidity_2m}%` }),
        ]),
        section('Next 24 hours', [
          chart(forecast.hourly.temperature_2m.slice(0, 24), { kind: 'line', labels: ['now', '+12 h', '+24 h'] }),
        ]),
        section('Days ahead', [forecastList(daily, true)], { priority: 'supporting' }),
      ];
    },
    async large(host) {
      await load(host);
      if (!latest) return unavailable();
      const forecast = latest.forecast, current = forecast.current, daily = forecast.daily;
      const now = describe(current.weather_code);
      return [
        split([
          column([
            grid(2, [
              stat(latest.place.name, Math.round(current.temperature_2m), { unit: '°C', icon: now.symbol, caption: now.label }),
              stat('Feels like', Math.round(current.apparent_temperature), { unit: '°C', caption: `Humidity ${current.relative_humidity_2m}%` }),
            ]),
            section('Next 24 hours', [
              chart(forecast.hourly.temperature_2m.slice(0, 24), { kind: 'line', labels: ['now', '+12 h', '+24 h'] }),
            ]),
            keyValue('Wind', `${Math.round(current.wind_speed_10m)} km/h`, { mono: true }),
          ], { spacing: 'normal' }),
          column([
            section('5-day forecast', [forecastList(daily, false)]),
            failure ? note(`Showing last reading. ${failure}`, { tone: 'warn' }) : note(`Updated ${host.format.ago(loadedAt)} · Open-Meteo`),
          ], { spacing: 'normal' }),
        ], { weights: [1.15, 1] }),
      ];
    },
  },
  configure(host) {
    const place = host.storage.get('place', null);
    return [
      section('Location', [
        place ? keyValue('Current place', place.name) : note('Using your local time zone city.'),
        field('Change place', 'setPlace', { icon: 'magnifyingglass', submitLabel: 'Find' }),
        failure ? note(failure, { tone: 'warn', icon: 'exclamationmark.triangle.fill' }) : null,
      ].filter(Boolean)),
      button('Refresh forecast', 'retry', { icon: 'arrow.clockwise' }),
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

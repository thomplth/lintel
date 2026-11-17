const defaultZones = ['UTC', 'America/Los_Angeles', 'Europe/London', 'Asia/Tokyo'];
const dateOrders = ['day-month', 'month-day', 'dmy', 'mdy', 'iso'];
const hourStyles = { '24-hour': false, '12-hour': true };
const minutesPerDay = 24 * 60;
const weekdayInitials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const longWeekdays = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const longMonths = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
  'November', 'December'];
const citiesSharingAZone = {
  'San Francisco': 'America/Los_Angeles', 'San Diego': 'America/Los_Angeles', 'San Jose': 'America/Los_Angeles',
  Seattle: 'America/Los_Angeles', Portland: 'America/Los_Angeles', 'Las Vegas': 'America/Los_Angeles',
  Washington: 'America/New_York', Boston: 'America/New_York', Miami: 'America/New_York', Atlanta: 'America/New_York',
  Philadelphia: 'America/New_York', Austin: 'America/Chicago', Dallas: 'America/Chicago', Houston: 'America/Chicago',
  'Salt Lake City': 'America/Denver', Montreal: 'America/Toronto', 'Rio de Janeiro': 'America/Sao_Paulo',
  Munich: 'Europe/Berlin', Frankfurt: 'Europe/Berlin', Hamburg: 'Europe/Berlin', Barcelona: 'Europe/Madrid',
  Milan: 'Europe/Rome', Geneva: 'Europe/Zurich', Manchester: 'Europe/London', Edinburgh: 'Europe/London',
  'Tel Aviv': 'Asia/Jerusalem', 'Abu Dhabi': 'Asia/Dubai', Mumbai: 'Asia/Kolkata', Delhi: 'Asia/Kolkata',
  'New Delhi': 'Asia/Kolkata', Bangalore: 'Asia/Kolkata', Beijing: 'Asia/Shanghai', Shenzhen: 'Asia/Shanghai',
  Guangzhou: 'Asia/Shanghai', Osaka: 'Asia/Tokyo', Kyoto: 'Asia/Tokyo', Hanoi: 'Asia/Bangkok', Canberra: 'Australia/Sydney',
  Wellington: 'Pacific/Auckland',
};

let unmatchedZone = null;
let zoneCatalog = null;

function choices(host) {
  return {
    weekday: host.storage.get('weekday', true),
    showDate: host.storage.get('showDate', true),
    year: host.storage.get('year', false),
    showTime: host.storage.get('showTime', true),
    seconds: host.storage.get('seconds', true),
    order: host.storage.get('dateOrder', 'day-month'),
    twelveHour: host.storage.get('hours', '24h') === '12h',
  };
}

function cityOf(zone) {
  return zone.split('/').pop().replace(/_/g, ' ');
}

function savedZones(host) {
  return host.storage.get('zones', defaultZones)
    .map((entry) => (typeof entry === 'string' ? { zone: entry, name: cityOf(entry) } : entry))
    .filter((entry) => entry && entry.zone);
}

function zoneOffsetMinutes(zone, now) {
  try {
    const name = new Intl.DateTimeFormat('en-US', { timeZone: zone, timeZoneName: 'longOffset' })
      .formatToParts(now).find((part) => part.type === 'timeZoneName').value;
    const match = /([+-])(\d{2}):(\d{2})/.exec(name);
    return match ? (match[1] === '-' ? -1 : 1) * (Number(match[2]) * 60 + Number(match[3])) : 0;
  } catch (error) {
    return null;
  }
}

function catalog() {
  if (!zoneCatalog) {
    const zones = Intl.supportedValuesOf('timeZone').filter((zone) => zone.includes('/') && !zone.startsWith('Etc/'));
    zoneCatalog = zones.map((zone) => ({ name: cityOf(zone), zone, value: zone }))
      .concat(Object.entries(citiesSharingAZone).map(([name, zone]) => ({ name, zone, value: name })))
      .concat([{ name: 'UTC', zone: 'UTC', value: 'UTC' }]);
  }
  return zoneCatalog;
}

function spelled(text) {
  return String(text).trim().toLowerCase().replace(/[\s_]+/g, ' ');
}

function matchRank(entry, query) {
  const name = spelled(entry.name);
  if (name.startsWith(query)) return 0;
  if (name.split(/[\s-]/).some((word) => word.startsWith(query))) return 1;
  if (spelled(entry.zone).includes(query)) return 2;
  return null;
}

function resolveZone(typed) {
  const query = spelled(typed);
  if (!query) return null;
  const exact = catalog().find((entry) => spelled(entry.name) === query || spelled(entry.zone) === query);
  if (exact) return { zone: exact.zone, name: exact.name };
  const prefixed = catalog().filter((entry) => matchRank(entry, query) === 0);
  return prefixed.length === 1 ? { zone: prefixed[0].zone, name: prefixed[0].name } : null;
}

function wallClock(minutes, twelveHour) {
  const hour = Math.floor(minutes / 60) % 24;
  const minute = String(minutes % 60).padStart(2, '0');
  if (twelveHour) return `${hour % 12 || 12}:${minute} ${hour < 12 ? 'AM' : 'PM'}`;
  return `${String(hour).padStart(2, '0')}:${minute}`;
}

function signedOffset(difference) {
  const hours = Math.floor(Math.abs(difference) / 60);
  const minutes = Math.abs(difference) % 60;
  const sign = difference > 0 ? '+' : '−';
  return minutes ? `${sign}${hours}:${String(minutes).padStart(2, '0')}` : `${sign}${hours} h`;
}

function zoneMoment(zone, now) {
  const offset = zoneOffsetMinutes(zone, now);
  if (offset === null) return null;
  const localOffset = -now.getTimezoneOffset();
  const utcMinutes = Math.floor(now.getTime() / 60000);
  const zoneMinutes = utcMinutes + offset;
  return {
    minuteOfDay: ((zoneMinutes % minutesPerDay) + minutesPerDay) % minutesPerDay,
    dayShift: Math.floor(zoneMinutes / minutesPerDay) - Math.floor((utcMinutes + localOffset) / minutesPerDay),
    difference: offset - localOffset,
  };
}

function worldClock(entry, now, twelveHour) {
  const moment = zoneMoment(entry.zone, now);
  const remove = { accessoryAction: 'removeZone', accessoryLabel: `Remove ${entry.name}`, payload: entry.name };
  if (!moment) return item(entry.name, { subtitle: 'Unknown time zone', icon: 'questionmark.circle', ...remove });
  const day = moment.dayShift > 0 ? 'Tomorrow' : moment.dayShift < 0 ? 'Yesterday' : 'Today';
  const isDaytime = moment.minuteOfDay >= 6 * 60 && moment.minuteOfDay < 18 * 60;
  return item(entry.name, {
    value: wallClock(moment.minuteOfDay, twelveHour),
    subtitle: moment.difference === 0 ? 'Same time' : `${day} · ${signedOffset(moment.difference)}`,
    icon: isDaytime ? 'sun.max' : 'moon',
    ...remove,
  });
}

function isoWeek(date) {
  const thursday = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  thursday.setUTCDate(thursday.getUTCDate() + 3 - ((thursday.getUTCDay() + 6) % 7));
  const firstOfYear = new Date(Date.UTC(thursday.getUTCFullYear(), 0, 1));
  return Math.ceil(((thursday - firstOfYear) / 86400000 + 1) / 7);
}

function calendar(now) {
  const year = now.getFullYear();
  const month = now.getMonth();
  const leading = (new Date(year, month, 1).getDay() + 6) % 7;
  const days = new Date(year, month + 1, 0).getDate();
  const previousDays = new Date(year, month, 0).getDate();
  const cells = weekdayInitials.map((day) => text(day, { role: 'caption', tone: 'tertiary' }));
  const outside = (day) => text(day, { role: 'label', mono: true, tone: 'tertiary' });
  for (let index = leading; index > 0; index -= 1) cells.push(outside(previousDays - index + 1));
  for (let day = 1; day <= days; day += 1) {
    const column = (leading + day - 1) % 7;
    if (day === now.getDate()) cells.push(badge(day, { tone: 'accent' }));
    else cells.push(text(day, { role: 'label', mono: true, tone: column >= 5 ? 'secondary' : undefined }));
  }
  for (let day = 1; (leading + days + day - 1) % 7 !== 0; day += 1) cells.push(outside(day));
  return section(`${longMonths[month]} ${year}`, [grid(7, cells, { spacing: 'tight' })], { trailing: `Week ${isoWeek(now)}` });
}

function header(host, now, c) {
  const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  const offset = -now.getTimezoneOffset();
  const gmt = offset === 0 ? 'GMT' : `GMT${offset > 0 ? '+' : '−'}${Math.floor(Math.abs(offset) / 60)}${Math.abs(offset) % 60 ? ':' + String(Math.abs(offset) % 60).padStart(2, '0') : ''}`;
  return column([
    text(host.format.time(now, { seconds: true, twelveHour: c.twelveHour }), { role: 'display', mono: true }),
    text(`${longWeekdays[now.getDay()]}, ${now.getDate()} ${longMonths[now.getMonth()]} ${now.getFullYear()}`, { role: 'label' }),
    text(`${cityOf(localZone)} · ${gmt}`, { role: 'caption', tone: 'tertiary' }),
  ], { spacing: 'tight' });
}

function dateOrderExamples(host, now, c) {
  const examples = (date) => dateOrders.map((order) => host.format.date(date, { order, year: c.year, weekday: false }));
  const today = examples(now);
  return new Set(today).size === today.length ? today : examples(new Date(2026, 11, 31));
}

function worldSection(now, zones, c) {
  return section('World', [
    zones.length
      ? list(zones.map((entry) => worldClock(entry, now, c.twelveHour)))
      : note('Add a city to compare its time with yours.'),
    field('Add a city', 'addZone', { icon: 'plus', suggest: 'suggestZones' }),
    ...(unmatchedZone ? [note(`No city or time zone matches “${unmatchedZone}”.`, { tone: 'warn' })] : []),
  ]);
}

function barSections(host, now, c) {
  const examples = dateOrderExamples(host, now, c);
  return [
    section('Time in the bar', [
      toggle('Show time', c.showTime, 'setShowTime'),
      ...(c.showTime ? [
        toggle('Seconds', c.seconds, 'setSeconds'),
        segmented(Object.keys(hourStyles), c.twelveHour ? '12-hour' : '24-hour', 'setHours'),
      ] : []),
    ]),
    section('Date in the bar', [
      toggle('Show date', c.showDate, 'setShowDate'),
      toggle('Weekday', c.weekday, 'setWeekday'),
      ...(c.showDate ? [
        toggle('Year', c.year, 'setYear'),
        segmented(examples, examples[Math.max(dateOrders.indexOf(c.order), 0)], 'setDateOrder'),
      ] : []),
    ]),
  ];
}

defineModule({
  meta: {
    id: 'clock',
    title: 'Clock',
    icon: 'clock',
    summary: 'The date and time in the bar, in a format you choose; a calendar and world clocks in the panel.',
    pinned: true,
    order: 90,
    refreshSeconds: 1,
    panelRefreshSeconds: 1,
    panelWidth: 'small',
  },
  render(host) {
    const c = choices(host);
    const now = new Date();
    const parts = [];
    if (c.showDate) parts.push(host.format.date(now, { order: c.order, year: c.year, weekday: c.weekday }));
    else if (c.weekday) parts.push(host.format.date(now, { weekday: true }).split(' ')[0]);
    if (c.showTime || parts.length === 0) parts.push(host.format.time(now, { seconds: c.seconds, twelveHour: c.twelveHour }));
    return text(parts.join('  '), { mono: true });
  },
  panel(host) {
    const now = new Date();
    const c = choices(host);
    return [header(host, now, c), calendar(now), worldSection(now, savedZones(host), c), ...barSections(host, now, c)];
  },
  actions: {
    suggestZones(host, typed) {
      const query = spelled(typed || '');
      if (!query) return [];
      const now = new Date();
      const shown = new Set(savedZones(host).map((entry) => spelled(entry.name)));
      return catalog()
        .map((entry) => ({ entry, rank: matchRank(entry, query) }))
        .filter(({ entry, rank }) => rank !== null && !shown.has(spelled(entry.name)))
        .sort((a, b) => a.rank - b.rank || a.entry.name.localeCompare(b.entry.name))
        .slice(0, 6)
        .map(({ entry }) => {
          const moment = zoneMoment(entry.zone, now);
          const region = entry.zone.includes('/') ? entry.zone.split('/')[0] : 'Coordinated Universal Time';
          return {
            title: entry.name,
            subtitle: moment ? `${region} · ${wallClock(moment.minuteOfDay, choices(host).twelveHour)}` : region,
            value: entry.value,
          };
        });
    },
    addZone(host, typed) {
      const resolved = resolveZone(typed);
      unmatchedZone = resolved ? null : String(typed).trim();
      if (!resolved) return;
      const zones = savedZones(host).filter((entry) => spelled(entry.name) !== spelled(resolved.name));
      host.storage.set('zones', zones.concat(resolved).slice(-8));
    },
    removeZone(host, name) {
      host.storage.set('zones', savedZones(host).filter((entry) => entry.name !== name));
    },
    setHours(host, label) {
      host.storage.set('hours', hourStyles[label] ? '12h' : '24h');
    },
    setShowTime: (host, isOn) => host.storage.set('showTime', !!isOn),
    setSeconds: (host, isOn) => host.storage.set('seconds', !!isOn),
    setShowDate: (host, isOn) => host.storage.set('showDate', !!isOn),
    setWeekday: (host, isOn) => host.storage.set('weekday', !!isOn),
    setYear: (host, isOn) => host.storage.set('year', !!isOn),
    setDateOrder(host, example) {
      const order = dateOrders[dateOrderExamples(host, new Date(), choices(host)).indexOf(example)];
      if (order) host.storage.set('dateOrder', order);
    },
  },
});

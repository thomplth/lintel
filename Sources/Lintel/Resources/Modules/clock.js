const defaultZones = ['UTC', 'America/Los_Angeles', 'Europe/London', 'Asia/Tokyo'];
const dateOrders = { 'D Mon': 'day-month', 'Mon D': 'month-day', 'DD/MM': 'dmy', 'MM/DD': 'mdy', 'Y-M-D': 'iso' };
const hourStyles = { '24-hour': false, '12-hour': true };
const partToggles = [
  ['Weekday', 'weekday', 'setWeekday'], ['Date', 'showDate', 'setShowDate'], ['Year', 'year', 'setYear'],
  ['Time', 'showTime', 'setShowTime'], ['Seconds', 'seconds', 'setSeconds'],
];

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

function labelFor(table, value) {
  return Object.keys(table).find((label) => table[label] === value);
}

const minutesPerDay = 24 * 60;
let unmatchedZone = null;
let chosenZone = null;

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

function cityName(zone) {
  return zone.split('/').pop().replace(/_/g, ' ');
}

function resolveZone(typed) {
  const wanted = String(typed).trim().toLowerCase().replace(/[\s_]+/g, ' ');
  if (!wanted) return null;
  const zones = Intl.supportedValuesOf('timeZone').concat('UTC');
  const spelled = (zone) => zone.toLowerCase().replace(/_/g, ' ');
  const byCity = (test) => zones.filter((zone) => test(spelled(cityName(zone))));
  const exact = zones.find((zone) => spelled(zone) === wanted) || byCity((city) => city === wanted)[0];
  if (exact) return exact;
  const prefixed = byCity((city) => city.startsWith(wanted));
  return prefixed.length === 1 ? prefixed[0] : null;
}

function wallClock(minutes, twelveHour) {
  const hour = Math.floor(minutes / 60) % 24;
  const minute = String(minutes % 60).padStart(2, '0');
  if (twelveHour) return `${hour % 12 || 12}:${minute} ${hour < 12 ? 'AM' : 'PM'}`;
  return `${String(hour).padStart(2, '0')}:${minute}`;
}

function offsetPhrase(difference) {
  if (difference === 0) return 'Same time';
  const hours = Math.floor(Math.abs(difference) / 60);
  const minutes = Math.abs(difference) % 60;
  const amount = [hours && `${hours} h`, minutes && `${minutes} min`].filter(Boolean).join(' ');
  return `${amount} ${difference > 0 ? 'ahead' : 'behind'}`;
}

function worldClock(zone, now, twelveHour) {
  const offset = zoneOffsetMinutes(zone, now);
  const title = cityName(zone);
  if (offset === null) return item(title, { value: 'unknown zone', icon: 'globe', action: 'selectZone', payload: zone });
  const localOffset = -now.getTimezoneOffset();
  const utcMinutes = Math.floor(now.getTime() / 60000);
  const zoneMinutes = utcMinutes + offset;
  const dayShift = Math.floor(zoneMinutes / minutesPerDay) - Math.floor((utcMinutes + localOffset) / minutesPerDay);
  const day = dayShift > 0 ? 'Tomorrow' : dayShift < 0 ? 'Yesterday' : 'Today';
  const difference = offset - localOffset;
  return item(title, {
    value: wallClock(((zoneMinutes % minutesPerDay) + minutesPerDay) % minutesPerDay, twelveHour),
    subtitle: difference === 0 ? offsetPhrase(0) : `${day}, ${offsetPhrase(difference)}`,
    icon: zone === chosenZone ? 'checkmark.circle.fill' : 'globe',
    tone: zone === chosenZone ? 'accent' : undefined,
    action: 'selectZone',
    payload: zone,
  });
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
    const first = new Date(now.getFullYear(), now.getMonth(), 1);
    const leading = (first.getDay() + 6) % 7;
    const days = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
    const cells = ['M', 'T', 'W', 'T', 'F', 'S', 'S'].map((day) => text(day, { role: 'caption', tone: 'tertiary' }));
    for (let blank = 0; blank < leading; blank += 1) cells.push(text(''));
    for (let day = 1; day <= days; day += 1) {
      const isToday = day === now.getDate();
      cells.push(text(day, { role: 'label', mono: true, tone: isToday ? 'accent' : 'primary', weight: isToday ? 'bold' : 'regular' }));
    }
    const zones = host.storage.get('zones', defaultZones);
    const c = choices(host);
    return [
      column([
        text(host.format.time(now, { seconds: true, twelveHour: c.twelveHour }), { role: 'display', mono: true }),
        text(host.format.date(now, { order: c.order, year: true }), { role: 'label' }),
      ], { spacing: 'tight' }),
      section(now.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' }), [grid(7, cells, { spacing: 'tight' })]),
      section('World', [
        list(zones.map((zone) => worldClock(zone, now, c.twelveHour))),
        ...(zones.includes(chosenZone)
          ? [button(`Remove ${cityName(chosenZone)}`, 'removeZone', { icon: 'trash', style: 'destructive', payload: chosenZone })]
          : []),
        field('Add a city, e.g. Paris', 'addZone', { icon: 'plus' }),
        ...(unmatchedZone ? [note(`No time zone matches \u201C${unmatchedZone}\u201D.`, { tone: 'warn' })] : []),
      ]),
      section('In the bar', [
        segmented(Object.keys(hourStyles), c.twelveHour ? '12-hour' : '24-hour', 'setHours'),
        segmented(Object.keys(dateOrders), labelFor(dateOrders, c.order) || 'D Mon', 'setDateOrder'),
        ...partToggles.map(([label, key, action]) => toggle(label, c[key], action)),
      ]),
    ];
  },
  actions: {
    addZone(host, typed) {
      const zone = resolveZone(typed);
      unmatchedZone = zone ? null : String(typed).trim();
      if (!zone) return;
      const zones = host.storage.get('zones', defaultZones).filter((existing) => existing !== zone);
      host.storage.set('zones', zones.concat(zone).slice(-8));
    },
    selectZone(host, zone) {
      chosenZone = chosenZone === zone ? null : zone;
    },
    removeZone(host, zone) {
      chosenZone = null;
      host.storage.set('zones', host.storage.get('zones', defaultZones).filter((existing) => existing !== zone));
    },
    setHours(host, label) {
      host.storage.set('hours', hourStyles[label] ? '12h' : '24h');
    },
    ...Object.fromEntries(partToggles.map(([, key, action]) => [action, (host, isOn) => host.storage.set(key, !!isOn)])),
    setDateOrder(host, label) {
      if (dateOrders[label]) host.storage.set('dateOrder', dateOrders[label]);
    },
  },
});

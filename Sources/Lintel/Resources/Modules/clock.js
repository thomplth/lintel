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

function zoneTime(zone, now) {
  try {
    return now.toLocaleTimeString('en-GB', { timeZone: zone, hour: '2-digit', minute: '2-digit' });
  } catch (error) {
    return null;
  }
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
        list(zones.map((zone) => item(zone.split('/').pop().replace(/_/g, ' '), {
          value: zoneTime(zone, now) || 'unknown zone', icon: 'globe', action: 'removeZone', payload: zone,
        }))),
        field('Add a zone, e.g. Europe/Paris', 'addZone', { icon: 'plus' }),
        note('Click a zone to remove it.'),
      ]),
      section('In the bar', [
        segmented(Object.keys(hourStyles), c.twelveHour ? '12-hour' : '24-hour', 'setHours'),
        segmented(Object.keys(dateOrders), labelFor(dateOrders, c.order) || 'D Mon', 'setDateOrder'),
        ...partToggles.map(([label, key, action]) => toggle(label, c[key], action)),
      ]),
    ];
  },
  actions: {
    addZone(host, zone) {
      const name = String(zone).trim().replace(/ /g, '_');
      if (!zoneTime(name, new Date())) return;
      const zones = host.storage.get('zones', defaultZones).filter((existing) => existing !== name);
      host.storage.set('zones', zones.concat(name).slice(-8));
    },
    removeZone(host, zone) {
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

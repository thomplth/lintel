const defaultZones = ['UTC', 'America/Los_Angeles', 'Europe/London', 'Asia/Tokyo'];

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
    summary: 'The time in the bar; a calendar and world clocks in the panel.',
    pinned: true,
    order: 90,
    refreshSeconds: 1,
    panelRefreshSeconds: 1,
    panelWidth: 'small',
  },
  render(host) {
    return text(host.format.time(null, { seconds: host.storage.get('seconds', true) }), { mono: true });
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
    return [
      column([
        text(host.format.time(now, { seconds: true }), { role: 'display', mono: true }),
        text(host.format.date(now, 'long'), { role: 'label' }),
      ], { spacing: 'tight' }),
      section(now.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' }), [grid(7, cells, { spacing: 'tight' })]),
      section('World', [
        list(zones.map((zone) => item(zone.split('/').pop().replace(/_/g, ' '), {
          value: zoneTime(zone, now) || 'unknown zone', icon: 'globe', action: 'removeZone', payload: zone,
        }))),
        field('Add a zone, e.g. Europe/Paris', 'addZone', { icon: 'plus' }),
        note('Click a zone to remove it.'),
      ]),
      toggle('Show seconds in the bar', host.storage.get('seconds', true), 'setSeconds'),
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
    setSeconds(host, isOn) {
      host.storage.set('seconds', !!isOn);
    },
  },
});

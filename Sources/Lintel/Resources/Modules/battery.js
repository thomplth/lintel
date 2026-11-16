function symbolFor(battery) {
  if (battery.charging) return 'battery.100percent.bolt';
  const level = battery.percent > 87 ? 100 : battery.percent > 62 ? 75 : battery.percent > 37 ? 50 : battery.percent > 12 ? 25 : 0;
  return `battery.${level}percent`;
}

function toneFor(battery) {
  if (battery.charging || battery.plugged) return undefined;
  return battery.percent <= 10 ? 'bad' : battery.percent <= 20 ? 'warn' : undefined;
}

defineModule({
  meta: {
    id: 'battery',
    title: 'Battery',
    icon: 'battery.75percent',
    summary: 'Charge level in the bar; time remaining and battery health in the panel.',
    pinned: true,
    order: 70,
    refreshSeconds: 30,
    panelWidth: 'small',
  },
  render(host) {
    const battery = host.system().battery;
    if (!battery) return icon('powerplug');
    host.attention(toneFor(battery) === 'bad');
    return row([
      icon(symbolFor(battery), { tone: toneFor(battery) }),
      text(`${battery.percent}%`, { mono: true, tone: toneFor(battery) }),
    ]);
  },
  panel(host) {
    const battery = host.system().battery;
    if (!battery) {
      return [empty('powerplug', 'No battery', { message: 'This Mac runs on mains power.' })];
    }
    const state = battery.charging ? 'Charging' : battery.plugged ? 'On adapter' : 'On battery';
    const time = battery.minutesRemaining === null ? 'Calculating' : host.format.duration(battery.minutesRemaining * 60);
    const tiles = [stat('Charge', battery.percent, { unit: '%', tone: toneFor(battery), caption: state })];
    if (battery.charging) tiles.push(stat('Until full', time));
    else if (!battery.plugged) tiles.push(stat('Remaining', time));
    const details = [keyValue('Power source', battery.plugged ? 'Power adapter' : 'Battery')];
    if (battery.cycles !== null) details.push(keyValue('Cycle count', battery.cycles, { mono: true }));
    return [
      grid(tiles.length, tiles),
      battery.health === null ? null : meter('Maximum capacity', battery.health, {
        value: host.format.percent(battery.health), tone: battery.health < 0.8 ? 'warn' : 'good',
      }),
      section('Details', details),
    ];
  },
});

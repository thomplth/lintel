function symbolFor(battery) {
  if (battery.charging) return 'battery.100percent.bolt';
  const level = battery.percent > 87 ? 100 : battery.percent > 62 ? 75 : battery.percent > 37 ? 50 : battery.percent > 12 ? 25 : 0;
  return `battery.${level}percent`;
}

function toneFor(battery) {
  if (battery.charging || battery.plugged) return undefined;
  return battery.percent <= 10 ? 'bad' : battery.percent <= 20 ? 'warn' : undefined;
}

function stateLabel(battery) {
  return battery.charging ? 'Charging' : battery.plugged ? 'On adapter' : 'On battery';
}

function timeLabel(host, battery) {
  return battery.minutesRemaining === null ? 'Calculating' : host.format.duration(battery.minutesRemaining * 60);
}

defineModule({
  meta: {
    id: 'battery',
    title: 'Battery',
    icon: 'battery.75percent',
    summary: 'Charge level in the bar; live charge, time remaining, history and health as a responsive widget.',
    pinned: true,
    order: 70,
    refreshSeconds: 30,
    panelRefreshSeconds: 15,
    defaultShape: 'compact',
  },
  chip(host) {
    const battery = host.system().battery;
    if (!battery) return icon('powerplug');
    host.history('charge', battery.percent, 60);
    host.attention(toneFor(battery) === 'bad');
    return row([
      icon(symbolFor(battery), { tone: toneFor(battery) }),
      text(`${battery.percent}%`, { mono: true, tone: toneFor(battery) }),
    ]);
  },
  widget(host) {
    const battery = host.system().battery;
    if (!battery) {
      return [empty('powerplug', 'No battery', { message: 'This Mac runs on mains power.' })];
    }
    const history = host.history('charge', battery.percent, 60);
    const time = timeLabel(host, battery);
    const tiles = [stat('Charge', battery.percent, { unit: '%', icon: symbolFor(battery), tone: toneFor(battery), caption: stateLabel(battery) })];
    if (battery.charging) tiles.push(stat('Until full', time));
    else if (!battery.plugged) tiles.push(stat('Remaining', time));
    const details = [
      battery.health === null ? null : meter('Maximum capacity', battery.health, {
        value: host.format.percent(battery.health), tone: battery.health < 0.8 ? 'warn' : 'good',
      }),
      keyValue('Power source', battery.plugged ? 'Power adapter' : 'Battery'),
      battery.cycles !== null ? keyValue('Cycle count', battery.cycles, { mono: true }) : null,
    ].filter(Boolean);
    return [
      grid(tiles.length, tiles),
      history.length >= 2 ? section('Recent charge', [chart(history, { kind: 'area', min: 0, max: 100, tone: toneFor(battery) || 'good' })], { priority: 'supporting' }) : null,
      section('Health & Power', details, { elastic: true, priority: 'supporting' }),
    ].filter(Boolean);
  },
});

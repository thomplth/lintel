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
    summary: 'Charge level in the bar; live charge, time remaining, history and health as a widget.',
    pinned: true,
    order: 70,
    refreshSeconds: 30,
    panelRefreshSeconds: 15,
    sizes: ['chip', 'small', 'wide', 'medium'],
    defaultSize: 'wide',
  },
  views: {
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
    small(host) {
      const battery = host.system().battery;
      if (!battery) return [empty('powerplug', 'Mains power')];
      host.history('charge', battery.percent, 60);
      const time = battery.charging || !battery.plugged ? timeLabel(host, battery) : 'Plugged in';
      return [
        column([
          row([icon(symbolFor(battery), { tone: toneFor(battery) }), text('Battery', { role: 'caption' }), spacer(), ring(battery.percent / 100, { tone: toneFor(battery) || 'accent' })]),
          text(`${battery.percent}%`, { role: 'display', mono: true, tone: toneFor(battery) }),
          text(stateLabel(battery), { role: 'label' }),
          text(time, { role: 'caption', tone: 'tertiary', mono: true }),
        ], { spacing: 'tight' }),
      ];
    },
    wide(host) {
      const battery = host.system().battery;
      if (!battery) return [empty('powerplug', 'No battery', { message: 'This Mac runs on mains power.' })];
      host.history('charge', battery.percent, 60);
      const time = timeLabel(host, battery);
      const details = [
        battery.health === null ? null : meter('Max capacity', battery.health, {
          value: host.format.percent(battery.health), tone: battery.health < 0.8 ? 'warn' : 'good',
        }),
        keyValue('Source', battery.plugged ? 'Adapter' : 'Battery'),
        battery.cycles !== null ? keyValue('Cycles', battery.cycles, { mono: true }) : null,
      ].filter(Boolean);
      return [
        split([
          stat('Charge', battery.percent, {
            unit: '%', icon: symbolFor(battery), tone: toneFor(battery),
            caption: battery.charging ? `Full in ${time}` : battery.plugged ? 'On adapter' : `${time} left`,
          }),
          column(details, { spacing: 'normal' }),
        ], { weights: [1, 1.15] }),
      ];
    },
    medium(host) {
      const battery = host.system().battery;
      if (!battery) {
        return [empty('powerplug', 'No battery', { message: 'This Mac runs on mains power.' })];
      }
      const history = host.history('charge', battery.percent, 60);
      const time = timeLabel(host, battery);
      const tiles = [stat('Charge', battery.percent, { unit: '%', icon: symbolFor(battery), tone: toneFor(battery), caption: stateLabel(battery) })];
      if (battery.charging) tiles.push(stat('Until full', time));
      else if (!battery.plugged) tiles.push(stat('Remaining', time));
      const details = [keyValue('Power source', battery.plugged ? 'Power adapter' : 'Battery')];
      if (battery.cycles !== null) details.push(keyValue('Cycle count', battery.cycles, { mono: true }));
      return [
        grid(tiles.length, tiles),
        history.length >= 2 ? section('Recent charge', [chart(history, { kind: 'area', min: 0, max: 100, tone: toneFor(battery) || 'good' })]) : null,
        battery.health === null ? null : meter('Maximum capacity', battery.health, {
          value: host.format.percent(battery.health), tone: battery.health < 0.8 ? 'warn' : 'good',
        }),
        section('Details', details, { priority: 'detail' }),
      ].filter(Boolean);
    },
  },
});

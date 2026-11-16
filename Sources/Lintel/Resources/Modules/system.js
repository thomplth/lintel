function loadTone(fraction) {
  return fraction >= 0.9 ? 'bad' : fraction >= 0.7 ? 'warn' : undefined;
}

defineModule({
  meta: {
    id: 'system',
    title: 'System',
    icon: 'cpu',
    summary: 'Processor and memory load in the bar; history, cores, memory and the busiest processes in the panel.',
    pinned: false,
    order: 20,
    refreshSeconds: 2,
    panelRefreshSeconds: 2,
  },
  render(host) {
    const system = host.system();
    const history = host.history('cpu', system.cpu, 60);
    const memory = system.memoryTotal > 0 ? system.memoryUsed / system.memoryTotal : 0;
    return row([
      icon('cpu', { tone: loadTone(system.cpu) }),
      sparkline(history.slice(-24)),
      text(host.format.percent(system.cpu), { mono: true, tone: loadTone(system.cpu) }),
      icon('memorychip', { tone: loadTone(memory) }),
      text(host.format.percent(memory), { mono: true, tone: loadTone(memory) }),
    ]);
  },
  panel(host) {
    const system = host.system();
    const format = host.format;
    const history = host.history('cpu');
    const memory = system.memoryTotal > 0 ? system.memoryUsed / system.memoryTotal : 0;
    const tiles = [
      stat('Processor', Math.round(system.cpu * 100), { unit: '%', icon: 'cpu', tone: loadTone(system.cpu) }),
      stat('Memory', Math.round(memory * 100), { unit: '%', icon: 'memorychip', tone: loadTone(memory) }),
    ];
    if (system.gpu !== null) {
      tiles.push(stat('Graphics', Math.round(system.gpu * 100), { unit: '%', icon: 'display', tone: loadTone(system.gpu) }));
    }
    const thermal = { nominal: undefined, fair: 'warn', serious: 'bad', critical: 'bad' }[system.thermal];
    return [
      grid(tiles.length, tiles),
      section('Processor', [
        chart(history.map((value) => value * 100), { min: 0, max: 100, labels: [`${history.length * 2} s ago`, 'now'] }),
        chart(system.cores.map((value) => value * 100), { kind: 'bar', height: 'small', min: 0, max: 100 }),
        keyValue('Load average', system.loadAverage.map((value) => value.toFixed(2)).join('  '), { mono: true }),
      ], { trailing: `${system.cores.length} cores` }),
      section('Memory', [
        meter('In use', memory, { value: `${format.bytes(system.memoryUsed)} of ${format.bytes(system.memoryTotal)}`, tone: loadTone(memory) }),
        meter('Pressure', system.memoryPressure, { value: format.percent(system.memoryPressure), tone: loadTone(system.memoryPressure) || 'good' }),
        keyValue('Swap used', format.bytes(system.swapUsed), { mono: true }),
      ]),
      section('Busiest processes', [
        list(host.processes().slice(0, 5).map((process) => item(process.name, {
          subtitle: format.bytes(process.memory), value: format.percent(process.cpu), icon: 'gearshape',
        }))),
      ], { trailing: 'share of one core' }),
      section('Machine', [
        keyValue('Uptime', format.duration(system.uptime)),
        keyValue('Thermal state', system.thermal, { tone: thermal }),
      ]),
    ];
  },
});

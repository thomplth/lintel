function loadTone(fraction) {
  return fraction >= 0.9 ? 'bad' : fraction >= 0.7 ? 'warn' : undefined;
}

function sample(host) {
  const system = host.system();
  const history = host.history('cpu', system.cpu, 60);
  const memory = system.memoryTotal > 0 ? system.memoryUsed / system.memoryTotal : 0;
  return { system, history, memory };
}

defineModule({
  meta: {
    id: 'system',
    title: 'System',
    icon: 'cpu',
    summary: 'Processor and memory load in the bar; history, memory and busiest processes as a responsive widget.',
    pinned: false,
    order: 20,
    refreshSeconds: 2,
    panelRefreshSeconds: 2,
    defaultShape: 'card',
  },
  chip(host) {
    const { system, history, memory } = sample(host);
    return row([
      icon('cpu', { tone: loadTone(system.cpu) }),
      sparkline(history.slice(-24)),
      text(host.format.percent(system.cpu), { mono: true, tone: loadTone(system.cpu) }),
      icon('memorychip', { tone: loadTone(memory) }),
      text(host.format.percent(memory), { mono: true, tone: loadTone(memory) }),
    ]);
  },
  widget(host) {
    const { system, history, memory } = sample(host);
    const format = host.format;
    const tiles = [
      stat('CPU', Math.round(system.cpu * 100), { unit: '%', icon: 'cpu', tone: loadTone(system.cpu) }),
      stat('Memory', Math.round(memory * 100), { unit: '%', icon: 'memorychip', tone: loadTone(memory) }),
    ];
    if (system.gpu !== null) {
      tiles.push(stat('GPU', Math.round(system.gpu * 100), { unit: '%', icon: 'display', tone: loadTone(system.gpu) }));
    }
    const thermal = { nominal: undefined, fair: 'warn', serious: 'bad', critical: 'bad' }[system.thermal];
    const procs = host.processes().slice(0, 10);
    const processes = procs.length > 0 ? list(procs.map((process) => item(process.name, {
      subtitle: format.bytes(process.memory),
      value: format.percent(process.cpu),
      icon: 'gearshape',
    }))) : null;
    return [
      split([
        column([
          grid(tiles.length, tiles),
          section('Processor', [
            chart(history.map((v) => v * 100), { min: 0, max: 100, labels: [`${history.length * 2} s ago`, 'now'] }),
          ], { trailing: `${system.cores.length} cores` }),
          row([
            text(`Uptime ${format.duration(system.uptime)}`, { role: 'caption', tone: 'secondary' }),
            spacer(),
            text(`Thermal: ${system.thermal}`, { role: 'caption', tone: thermal || 'secondary' }),
          ], { priority: 'detail' }),
        ], { spacing: 'normal' }),
        column([
          section('Memory', [
            meter('In use', memory, { value: `${format.bytes(system.memoryUsed)} / ${format.bytes(system.memoryTotal)}`, tone: loadTone(memory) }),
            meter('Pressure', system.memoryPressure, { value: format.percent(system.memoryPressure), tone: loadTone(system.memoryPressure) || 'good' }),
            keyValue('Swap', format.bytes(system.swapUsed), { mono: true }),
          ], { elastic: true, priority: 'supporting' }),
          processes ? section('Busiest processes', [processes], { trailing: 'share of 1 core', priority: 'supporting' }) : null,
        ].filter(Boolean), { spacing: 'normal', priority: 'supporting' }),
      ], { weights: [1.15, 1] }),
    ];
  },
});

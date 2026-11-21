function loadTone(fraction) {
  return fraction >= 0.9 ? 'bad' : fraction >= 0.7 ? 'warn' : undefined;
}

function sample(host) {
  const system = host.system();
  const history = host.history('cpu', system.cpu, 60);
  const memory = system.memoryTotal > 0 ? system.memoryUsed / system.memoryTotal : 0;
  return { system, history, memory };
}

function statTiles(system, memory) {
  const tiles = [
    stat('CPU', Math.round(system.cpu * 100), { unit: '%', icon: 'cpu', tone: loadTone(system.cpu) }),
    stat('Memory', Math.round(memory * 100), { unit: '%', icon: 'memorychip', tone: loadTone(memory) }),
  ];
  if (system.gpu !== null) {
    tiles.push(stat('GPU', Math.round(system.gpu * 100), { unit: '%', icon: 'display', tone: loadTone(system.gpu) }));
  }
  return tiles;
}

function processList(host, compact) {
  const format = host.format;
  return list(host.processes().slice(0, 10).map((process) => item(process.name, {
    subtitle: format.bytes(process.memory),
    value: format.percent(process.cpu),
    icon: 'gearshape',
  })), { compact });
}

defineModule({
  meta: {
    id: 'system',
    title: 'System',
    icon: 'cpu',
    summary: 'Processor and memory load in the bar; history, cores, memory and busiest processes as a widget.',
    pinned: false,
    order: 20,
    refreshSeconds: 2,
    panelRefreshSeconds: 2,
    sizes: ['chip', 'small', 'wide', 'medium', 'large'],
    defaultSize: 'medium',
  },
  views: {
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
    small(host) {
      const { system, memory } = sample(host);
      const format = host.format;
      return [
        column([
          meter('CPU', system.cpu, { value: format.percent(system.cpu), tone: loadTone(system.cpu), icon: 'cpu' }),
          meter('Memory', memory, { value: format.percent(memory), tone: loadTone(memory), icon: 'memorychip' }),
          ...(system.gpu !== null ? [meter('GPU', system.gpu, { value: format.percent(system.gpu), tone: loadTone(system.gpu), icon: 'display' })] : []),
          spacer(),
          keyValue('Load', system.loadAverage[0].toFixed(2), { mono: true }),
        ], { spacing: 'normal' }),
      ];
    },
    wide(host) {
      const { system, history, memory } = sample(host);
      const format = host.format;
      return [
        split([
          column([
            stat('CPU', Math.round(system.cpu * 100), { unit: '%', icon: 'cpu', tone: loadTone(system.cpu) }),
            meter('Memory', memory, { value: format.percent(memory), tone: loadTone(memory) }),
          ], { spacing: 'tight' }),
          section('Processor', [
            chart(history.map((v) => v * 100), { min: 0, max: 100 }),
          ], { trailing: `${system.cores.length} cores` }),
        ], { weights: [1, 1.35] }),
      ];
    },
    medium(host) {
      const { system, history, memory } = sample(host);
      const format = host.format;
      const tiles = statTiles(system, memory);
      return [
        grid(tiles.length, tiles),
        section('Processor', [
          chart(history.map((v) => v * 100), { min: 0, max: 100, labels: [`${history.length * 2} s ago`, 'now'] }),
        ], { trailing: `${system.cores.length} cores` }),
        meter('Memory', memory, { value: `${format.bytes(system.memoryUsed)} of ${format.bytes(system.memoryTotal)}`, tone: loadTone(memory), icon: 'memorychip' }),
        section('Busiest processes', [processList(host, true)], { priority: 'supporting' }),
      ];
    },
    large(host) {
      const { system, history, memory } = sample(host);
      const format = host.format;
      const tiles = statTiles(system, memory);
      const thermal = { nominal: undefined, fair: 'warn', serious: 'bad', critical: 'bad' }[system.thermal];
      return [
        split([
          column([
            grid(tiles.length, tiles),
            section('Processor', [
              chart(history.map((v) => v * 100), { min: 0, max: 100, labels: [`${history.length * 2} s ago`, 'now'] }),
              chart(system.cores.map((v) => v * 100), { kind: 'bar', height: 'small', min: 0, max: 100 }),
            ], { trailing: `${system.cores.length} cores` }),
            row([
              text(`Uptime ${format.duration(system.uptime)}`, { role: 'caption', tone: 'secondary' }),
              spacer(),
              text(`Thermal: ${system.thermal}`, { role: 'caption', tone: thermal || 'secondary' }),
            ]),
          ], { spacing: 'normal' }),
          column([
            section('Memory', [
              meter('In use', memory, { value: `${format.bytes(system.memoryUsed)} / ${format.bytes(system.memoryTotal)}`, tone: loadTone(memory) }),
              meter('Pressure', system.memoryPressure, { value: format.percent(system.memoryPressure), tone: loadTone(system.memoryPressure) || 'good' }),
              keyValue('Swap', format.bytes(system.swapUsed), { mono: true }),
            ]),
            section('Busiest processes', [processList(host, false)], { trailing: 'share of 1 core' }),
          ], { spacing: 'normal' }),
        ], { weights: [1.15, 1] }),
      ];
    },
  },
});

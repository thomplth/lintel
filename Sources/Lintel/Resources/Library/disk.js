function sample(host) {
  const disk = host.disk();
  const read = host.history('read', disk.readRate, 60);
  const write = host.history('write', disk.writeRate, 60);
  return { disk, read, write };
}

function volumeTone(used) {
  return used > 0.95 ? 'bad' : used > 0.85 ? 'warn' : undefined;
}

defineModule({
  meta: {
    id: 'disk',
    title: 'Storage',
    icon: 'internaldrive',
    summary: 'Free space in the bar; volumes and live read/write activity in a responsive widget.',
    pinned: false,
    order: 28,
    refreshSeconds: 5,
    panelRefreshSeconds: 2,
    defaultShape: 'card',
  },
  chip(host) {
    const { disk } = sample(host);
    const volume = disk.volumes[0];
    if (!volume) return icon('internaldrive');
    const used = 1 - volume.free / volume.total;
    return row([
      icon('internaldrive', { tone: volumeTone(used) }),
      text(host.format.bytes(volume.free), { mono: true }),
    ]);
  },
  widget(host) {
    const { disk, read, write } = sample(host);
    const format = host.format;
    if (disk.volumes.length === 0) return [empty('internaldrive', 'No volumes found')];
    return [
      split([
        section('Volumes', disk.volumes.map((volume) => {
          const used = 1 - volume.free / volume.total;
          return meter(volume.name, used, {
            value: `${format.bytes(volume.free)} free of ${format.bytes(volume.total)}`,
            tone: volumeTone(used),
            icon: 'internaldrive',
          });
        }), { elastic: true }),
        column([
          grid(2, [
            stat('Read', format.rate(disk.readRate), { icon: 'arrow.down.circle' }),
            stat('Write', format.rate(disk.writeRate), { icon: 'arrow.up.circle' }),
          ]),
          section('Throughput', [
            chart([
              { label: 'Read', values: read, tone: 'accent' },
              { label: 'Write', values: write, tone: 'orange' },
            ], { kind: 'area', min: 0 }),
          ], { priority: 'supporting' }),
        ], { spacing: 'normal', priority: 'supporting' }),
      ], { weights: [1, 1.15] }),
    ];
  },
});

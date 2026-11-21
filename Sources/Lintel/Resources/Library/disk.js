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
    summary: 'Free space in the bar; volumes and live read/write activity across widget sizes.',
    pinned: false,
    order: 28,
    refreshSeconds: 5,
    panelRefreshSeconds: 2,
    sizes: ['chip', 'small', 'wide', 'medium', 'large'],
    defaultSize: 'medium',
  },
  views: {
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
    small(host) {
      const { disk } = sample(host);
      const volume = disk.volumes[0];
      if (!volume) return [empty('internaldrive', 'No volumes')];
      const used = 1 - volume.free / volume.total;
      return [
        column([
          row([icon('internaldrive', { tone: volumeTone(used) || 'accent' }), text(volume.name, { role: 'caption' }), spacer(), ring(used, { tone: volumeTone(used) || 'accent' })]),
          text(host.format.bytes(volume.free), { role: 'display', mono: true }),
          text(`free of ${host.format.bytes(volume.total)}`, { role: 'caption', tone: 'tertiary' }),
          spacer(),
          meter('Used', used, { value: host.format.percent(used), tone: volumeTone(used) }),
        ], { spacing: 'tight' }),
      ];
    },
    wide(host) {
      const { disk } = sample(host);
      const format = host.format;
      if (disk.volumes.length === 0) return [empty('internaldrive', 'No volumes found')];
      return [
        split([
          section('Volumes', disk.volumes.slice(0, 3).map((volume) => {
            const used = 1 - volume.free / volume.total;
            return meter(volume.name, used, { value: `${format.bytes(volume.free)} free`, tone: volumeTone(used) });
          })),
          column([
            stat('Read', format.rate(disk.readRate), { icon: 'arrow.down.circle' }),
            keyValue('Write', format.rate(disk.writeRate), { mono: true }),
          ], { spacing: 'tight' }),
        ], { weights: [1.3, 1] }),
      ];
    },
    medium(host) {
      const { disk, read, write } = sample(host);
      const format = host.format;
      if (disk.volumes.length === 0) return [empty('internaldrive', 'No volumes found')];
      return [
        section('Volumes', disk.volumes.slice(0, 4).map((volume) => {
          const used = 1 - volume.free / volume.total;
          return meter(volume.name, used, {
            value: `${format.bytes(volume.free)} free of ${format.bytes(volume.total)}`,
            tone: volumeTone(used), icon: 'internaldrive',
          });
        })),
        grid(2, [
          stat('Read', format.rate(disk.readRate), { icon: 'arrow.down.circle' }),
          stat('Write', format.rate(disk.writeRate), { icon: 'arrow.up.circle' }),
        ]),
        chart([
          { label: 'Read', values: read, tone: 'accent' },
          { label: 'Write', values: write, tone: 'orange' },
        ], { kind: 'line', min: 0 }),
      ];
    },
    large(host) {
      const { disk, read, write } = sample(host);
      const format = host.format;
      if (disk.volumes.length === 0) return [empty('internaldrive', 'No volumes found')];
      return [
        split([
          section('Volumes', disk.volumes.slice(0, 8).map((volume) => {
            const used = 1 - volume.free / volume.total;
            return meter(volume.name, used, {
              value: `${format.bytes(volume.free)} free of ${format.bytes(volume.total)}`,
              tone: volumeTone(used), icon: 'internaldrive',
            });
          })),
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
            ]),
          ], { spacing: 'normal' }),
        ], { weights: [1, 1.15] }),
      ];
    },
  },
});

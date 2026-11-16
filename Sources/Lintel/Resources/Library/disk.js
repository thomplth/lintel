defineModule({
  meta: {
    id: 'disk',
    title: 'Storage',
    icon: 'internaldrive',
    summary: 'Free space on the startup volume in the bar; every volume and disk activity in the panel.',
    pinned: false,
    order: 28,
    refreshSeconds: 5,
    panelRefreshSeconds: 2,
  },
  render(host) {
    const disk = host.disk();
    host.history('read', disk.readRate, 60);
    host.history('write', disk.writeRate, 60);
    const volume = disk.volumes[0];
    if (!volume) return icon('internaldrive');
    const used = 1 - volume.free / volume.total;
    return row([
      icon('internaldrive', { tone: used > 0.95 ? 'bad' : used > 0.85 ? 'warn' : undefined }),
      text(host.format.bytes(volume.free), { mono: true }),
    ]);
  },
  panel(host) {
    const disk = host.disk(), format = host.format;
    if (disk.volumes.length === 0) return [empty('internaldrive', 'No volumes found')];
    return [
      section('Volumes', disk.volumes.slice(0, 6).map((volume) => {
        const used = 1 - volume.free / volume.total;
        return meter(volume.name, used, {
          value: `${format.bytes(volume.free)} free of ${format.bytes(volume.total)}`,
          tone: used > 0.95 ? 'bad' : used > 0.85 ? 'warn' : undefined, icon: 'internaldrive',
        });
      })),
      section('Activity', [
        grid(2, [
          stat('Read', format.rate(disk.readRate), { icon: 'arrow.down.circle' }),
          stat('Write', format.rate(disk.writeRate), { icon: 'arrow.up.circle' }),
        ]),
        chart([
          { label: 'Read', values: host.history('read'), tone: 'accent' },
          { label: 'Write', values: host.history('write'), tone: 'orange' },
        ], { kind: 'line', height: 'small', min: 0 }),
      ]),
    ];
  },
});

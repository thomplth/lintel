function record(host) {
  const network = host.network();
  const down = host.history('down', network.down, 60);
  const up = host.history('up', network.up, 60);
  return { network, down, up };
}

defineModule({
  meta: {
    id: 'network',
    title: 'Network',
    icon: 'network',
    summary: 'Download and upload speed in the bar; live throughput chart and Wi-Fi signal as a responsive widget.',
    pinned: false,
    order: 30,
    refreshSeconds: 2,
    panelRefreshSeconds: 2,
    defaultShape: 'card',
  },
  chip(host) {
    const { network } = record(host);
    if (!network.ip) return row([icon('wifi.slash', { tone: 'warn' }), text('offline', { tone: 'secondary' })]);
    return row([
      icon('arrow.down'), text(host.format.rate(network.down), { mono: true }),
      icon('arrow.up'), text(host.format.rate(network.up), { mono: true }),
    ]);
  },
  widget(host) {
    const { network, down, up } = record(host);
    const format = host.format;
    if (!network.ip) {
      return [empty('wifi.slash', 'Not connected', { message: 'No network interface has an address.' })];
    }
    const wifi = network.wifi;
    const signal = wifi ? Math.min(Math.max((wifi.rssi + 90) / 60, 0), 1) : 0;
    return [
      grid(2, [
        stat('Download', format.rate(network.down), { icon: 'arrow.down.circle' }),
        stat('Upload', format.rate(network.up), { icon: 'arrow.up.circle' }),
      ]),
      chart([
        { label: 'Download', values: down, tone: 'accent' },
        { label: 'Upload', values: up, tone: 'orange' },
      ], { kind: 'area', min: 0, labels: [`${down.length * 2} s ago`, 'now'] }),
      section('Connection', [
        keyValue('Interface', network.interface || 'unknown', { mono: true }),
        keyValue('Address', network.ip, { mono: true }),
        wifi ? meter('Signal', signal, { value: `${wifi.rssi} dBm`, tone: signal < 0.3 ? 'warn' : 'good', icon: 'wifi' }) : null,
      ].filter(Boolean), { elastic: true, priority: 'supporting' }),
    ];
  },
});

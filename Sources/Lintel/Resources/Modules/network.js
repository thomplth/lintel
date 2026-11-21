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
    summary: 'Download and upload speed in the bar; live throughput chart and Wi-Fi signal as a widget.',
    pinned: false,
    order: 30,
    refreshSeconds: 2,
    panelRefreshSeconds: 2,
    sizes: ['chip', 'small', 'wide', 'medium'],
    defaultSize: 'medium',
  },
  views: {
    chip(host) {
      const { network } = record(host);
      if (!network.ip) return row([icon('wifi.slash', { tone: 'warn' }), text('offline', { tone: 'secondary' })]);
      return row([
        icon('arrow.down'), text(host.format.rate(network.down), { mono: true }),
        icon('arrow.up'), text(host.format.rate(network.up), { mono: true }),
      ]);
    },
    small(host) {
      const { network } = record(host);
      const format = host.format;
      if (!network.ip) return [empty('wifi.slash', 'Offline')];
      const wifi = network.wifi;
      const signal = wifi ? Math.min(Math.max((wifi.rssi + 90) / 60, 0), 1) : 0;
      return [
        column([
          row([icon(wifi ? 'wifi' : 'network', { tone: 'accent' }), text(wifi && wifi.ssid ? wifi.ssid : (network.interface || 'Network'), { role: 'caption' })]),
          keyValue('Down', format.rate(network.down), { mono: true }),
          keyValue('Up', format.rate(network.up), { mono: true }),
          spacer(),
          wifi ? meter('Signal', signal, { value: `${wifi.rssi} dBm`, tone: signal < 0.3 ? 'warn' : 'good' }) : keyValue('IP', network.ip, { mono: true }),
        ], { spacing: 'tight' }),
      ];
    },
    wide(host) {
      const { network, down, up } = record(host);
      const format = host.format;
      if (!network.ip) return [empty('wifi.slash', 'Not connected', { message: 'No network interface has an address.' })];
      return [
        split([
          column([
            stat('Download', format.rate(network.down), { icon: 'arrow.down.circle' }),
            keyValue('Upload', format.rate(network.up), { mono: true }),
          ], { spacing: 'tight' }),
          chart([
            { label: 'Down', values: down, tone: 'accent' },
            { label: 'Up', values: up, tone: 'orange' },
          ], { kind: 'area', min: 0 }),
        ], { weights: [1, 1.3] }),
      ];
    },
    medium(host) {
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
        ].filter(Boolean), { priority: 'supporting' }),
      ];
    },
  },
});

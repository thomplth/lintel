function symbolFor(name) {
  const lowered = name.toLowerCase();
  if (lowered.indexOf('airpods') >= 0) return 'airpodspro';
  if (lowered.indexOf('keyboard') >= 0) return 'keyboard';
  if (lowered.indexOf('mouse') >= 0 || lowered.indexOf('trackpad') >= 0) return 'computermouse';
  if (lowered.indexOf('headphone') >= 0 || lowered.indexOf('buds') >= 0) return 'headphones';
  return 'dot.radiowaves.left.and.right';
}

function deviceRows(host, devices, compact) {
  return list(devices.slice(0, 12).map((device) => item(host.format.truncate(device.name, 28), {
    icon: symbolFor(device.name),
    value: device.battery === null ? undefined : `${device.battery}%`,
    tone: device.battery !== null && device.battery <= 20 ? 'warn' : undefined,
  })), { compact });
}

defineModule({
  meta: {
    id: 'bluetooth',
    title: 'Bluetooth',
    icon: 'dot.radiowaves.left.and.right',
    summary: 'Connected Bluetooth devices and their battery levels.',
    pinned: false,
    order: 55,
    refreshSeconds: 30,
    sizes: ['chip', 'small', 'wide', 'medium'],
    defaultSize: 'medium',
  },
  views: {
    chip(host) {
      const bluetooth = host.bluetooth();
      const connected = bluetooth.devices.filter((device) => device.connected);
      const lowest = connected.filter((device) => device.battery !== null).sort((a, b) => a.battery - b.battery)[0];
      if (!bluetooth.on) return icon('dot.radiowaves.left.and.right', { tone: 'tertiary' });
      if (lowest && lowest.battery <= 20) {
        return row([icon(symbolFor(lowest.name), { tone: 'warn' }), text(`${lowest.battery}%`, { mono: true, tone: 'warn' })]);
      }
      return connected.length === 0
        ? icon('dot.radiowaves.left.and.right', { tone: 'secondary' })
        : row([icon('dot.radiowaves.left.and.right'), text(connected.length, { mono: true })]);
    },
    small(host) {
      const bluetooth = host.bluetooth();
      if (!bluetooth.on) return [empty('dot.radiowaves.left.and.right', 'Bluetooth off')];
      const connected = bluetooth.devices.filter((device) => device.connected);
      return [
        row([icon('dot.radiowaves.left.and.right', { tone: 'accent' }), text('Bluetooth', { role: 'label', weight: 'semibold' }), spacer(), badge(connected.length)]),
        connected.length > 0 ? deviceRows(host, connected, true) : empty('dot.radiowaves.left.and.right', 'No devices'),
      ];
    },
    wide(host) {
      const bluetooth = host.bluetooth();
      if (!bluetooth.on) return [empty('dot.radiowaves.left.and.right', 'Bluetooth is off')];
      const connected = bluetooth.devices.filter((device) => device.connected);
      const others = bluetooth.devices.filter((device) => !device.connected);
      return [
        split([
          section('Connected', [connected.length > 0 ? deviceRows(host, connected, true) : empty('dot.radiowaves.left.and.right', 'None')], { trailing: String(connected.length) }),
          section('Paired', [others.length > 0 ? deviceRows(host, others, true) : note('No other paired devices.')], { trailing: String(others.length) }),
        ]),
      ];
    },
    medium(host) {
      const bluetooth = host.bluetooth();
      if (!bluetooth.on) return [empty('dot.radiowaves.left.and.right', 'Bluetooth is off')];
      const connected = bluetooth.devices.filter((device) => device.connected);
      const others = bluetooth.devices.filter((device) => !device.connected);
      return [
        connected.length > 0
          ? section('Connected', [deviceRows(host, connected, false)], { trailing: String(connected.length) })
          : empty('dot.radiowaves.left.and.right', 'Nothing connected'),
        others.length > 0 ? section('Paired', [deviceRows(host, others, true)], { trailing: String(others.length), priority: 'supporting' }) : null,
      ].filter(Boolean);
    },
  },
});

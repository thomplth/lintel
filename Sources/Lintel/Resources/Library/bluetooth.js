function symbolFor(name) {
  const lowered = name.toLowerCase();
  if (lowered.indexOf('airpods') >= 0) return 'airpodspro';
  if (lowered.indexOf('keyboard') >= 0) return 'keyboard';
  if (lowered.indexOf('mouse') >= 0 || lowered.indexOf('trackpad') >= 0) return 'computermouse';
  if (lowered.indexOf('headphone') >= 0 || lowered.indexOf('buds') >= 0) return 'headphones';
  return 'dot.radiowaves.left.and.right';
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
    panelWidth: 'small',
  },
  render(host) {
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
  panel(host) {
    const bluetooth = host.bluetooth();
    if (!bluetooth.on) return [empty('dot.radiowaves.left.and.right', 'Bluetooth is off')];
    const connected = bluetooth.devices.filter((device) => device.connected);
    const others = bluetooth.devices.filter((device) => !device.connected);
    const rows = (devices) => list(devices.slice(0, 10).map((device) => item(host.format.truncate(device.name, 30), {
      icon: symbolFor(device.name),
      value: device.battery === null ? undefined : `${device.battery}%`,
      tone: device.battery !== null && device.battery <= 20 ? 'warn' : undefined,
    })));
    return [
      connected.length > 0
        ? section('Connected', [rows(connected)])
        : empty('dot.radiowaves.left.and.right', 'Nothing connected'),
      others.length > 0 ? section('Paired', [rows(others)]) : null,
    ];
  },
});

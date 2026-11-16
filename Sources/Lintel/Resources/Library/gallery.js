const wave = Array.from({ length: 32 }, (unused, index) => 50 + 30 * Math.sin(index / 3) + 12 * Math.cos(index / 1.3));
const tones = ['primary', 'secondary', 'accent', 'good', 'warn', 'bad', 'info'];
let isOn = true, choice = 'Week', level = 0.6, entries = ['First entry'];

defineModule({
  meta: {
    id: 'gallery',
    title: 'Components',
    icon: 'square.grid.2x2',
    summary: 'Every component of the design system in one panel, for judging a theme at a glance.',
    pinned: false,
    order: 10,
    refreshSeconds: 60,
    panelWidth: 'large',
  },
  render() {
    return row([icon('square.grid.2x2'), sparkline(wave), text('42%', { mono: true }), gauge(0.42), ring(0.7), dot('good'), badge(3)]);
  },
  panel() {
    return [
      section('Text roles', [
        text('Display 1,234', { role: 'display', mono: true }),
        text('Title role', { role: 'title' }),
        text('Value role is the size of the bar itself'),
        text('Label role for supporting text', { role: 'label' }),
        text('Caption role for timestamps and footnotes', { role: 'caption' }),
      ]),
      section('Tones', [row(tones.map((tone) => badge(tone, { tone })), { spacing: 'tight' })]),
      section('Stats and meters', [
        grid(3, [
          stat('Requests', '12.4k', { icon: 'arrow.up.arrow.down', trend: 'up', caption: 'last hour' }),
          stat('Errors', 0.4, { unit: '%', tone: 'good' }),
          stat('Latency', 182, { unit: 'ms', tone: 'warn', trend: 'down' }),
        ]),
        meter('Quota used', 0.72, { value: '72 of 100 GB', icon: 'internaldrive' }),
        meter('Error budget', 0.93, { value: '93%', tone: 'bad' }),
        progress(0.35, { label: 'Uploading 7 of 20' }),
        progress(null, { label: 'Waiting for the server' }),
      ], { trailing: 'live' }),
      section('Charts', [
        chart(wave, { labels: ['1 h ago', 'now'] }),
        chart([
          { label: 'This week', values: wave.slice(0, 12) },
          { label: 'Last week', values: wave.slice(12, 24) },
        ], { kind: 'line', height: 'small' }),
        chart(wave.slice(0, 14), { kind: 'bar', height: 'small', tone: 'good' }),
      ]),
      section('Lists and details', [
        list([
          item('Deploy to production', { subtitle: 'main · 2 min ago', icon: 'checkmark.circle.fill', tone: 'good', value: '1m 12s' }),
          item('Run integration tests', { subtitle: 'feature/login · 9 min ago', icon: 'xmark.circle.fill', tone: 'bad', badge: 'failed' }),
          item('Open the dashboard', { icon: 'safari', url: 'https://example.com' }),
        ].concat(entries.map((entry) => item(entry, { icon: 'doc.text', action: 'remove', payload: entry })))),
        keyValue('Region', 'ap-east-1', { mono: true }),
        keyValue('Status', 'Degraded', { tone: 'warn' }),
        note('Notes carry explanations, timestamps and calm error text.', { icon: 'info.circle' }),
      ]),
      section('Controls', [
        segmented(['Day', 'Week', 'Month'], choice, 'choose'),
        toggle('Notify me when it changes', isOn, 'toggle', { icon: 'bell' }),
        slider(level, 'slide', { label: `Threshold ${Math.round(level * 100)}%`, icon: 'slider.horizontal.3' }),
        field('Add an entry', 'add', { icon: 'plus' }),
        grid(3, [
          button('Primary', 'noop', { style: 'primary', icon: 'play.fill' }),
          button('Secondary', 'noop'),
          button('Delete', 'noop', { style: 'destructive', icon: 'trash' }),
        ]),
      ]),
      divider(),
      empty('tray', 'Nothing here yet', { message: 'An empty state says what is missing and what to do next.', action: 'noop', actionLabel: 'Do it' }),
    ];
  },
  actions: {
    toggle(host, value) { isOn = !!value; },
    choose(host, value) { choice = value; },
    slide(host, value) { level = value; },
    add(host, value) { entries = entries.concat(host.format.truncate(value, 40)).slice(-4); },
    remove(host, value) { entries = entries.filter((entry) => entry !== value); },
    noop() {},
  },
});

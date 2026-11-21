const wave = Array.from({ length: 32 }, (unused, index) => 50 + 30 * Math.sin(index / 3) + 12 * Math.cos(index / 1.3));
const tones = ['primary', 'secondary', 'accent', 'good', 'warn', 'bad', 'info'];
let isOn = true, choice = 'Week', level = 0.6, entries = ['First entry'];

function sampleList() {
  return list([
    item('Deploy to production', { subtitle: 'main · 2 min ago', icon: 'checkmark.circle.fill', tone: 'good', value: '1m 12s' }),
    item('Run integration tests', { subtitle: 'feature/login · 9 min ago', icon: 'xmark.circle.fill', tone: 'bad', badge: 'failed' }),
    item('Open the dashboard', { icon: 'safari', url: 'https://example.com' }),
  ].concat(entries.map((entry) => item(entry, { icon: 'doc.text', action: 'remove', payload: entry }))));
}

defineModule({
  meta: {
    id: 'gallery',
    title: 'Components',
    icon: 'square.grid.2x2',
    summary: 'Every component of the design system across every widget size, for judging a theme at a glance.',
    pinned: false,
    order: 10,
    refreshSeconds: 60,
    sizes: ['chip', 'small', 'wide', 'medium', 'large'],
    defaultSize: 'large',
  },
  views: {
    chip() {
      return row([icon('square.grid.2x2'), sparkline(wave), text('42%', { mono: true }), gauge(0.42), ring(0.7), dot('good'), badge(3)]);
    },
    small() {
      return [
        stat('Requests', '12.4k', { icon: 'arrow.up.arrow.down', trend: 'up', caption: 'last hour' }),
        row(tones.slice(2, 6).map((tone) => badge(tone, { tone })), { spacing: 'tight' }),
        meter('Quota', 0.72, { value: '72%' }),
      ];
    },
    wide() {
      return [
        split([
          column([
            stat('Requests', '12.4k', { icon: 'arrow.up.arrow.down', trend: 'up', caption: 'last hour' }),
            meter('Error budget', 0.93, { value: '93%', tone: 'bad' }),
          ], { spacing: 'tight' }),
          chart(wave, { labels: ['1 h ago', 'now'] }),
        ], { weights: [1, 1.2] }),
      ];
    },
    medium() {
      return [
        grid(3, [
          stat('Requests', '12.4k', { trend: 'up' }),
          stat('Errors', 0.4, { unit: '%', tone: 'good' }),
          stat('Latency', 182, { unit: 'ms', tone: 'warn', trend: 'down' }),
        ]),
        chart(wave, { labels: ['1 h ago', 'now'] }),
        sampleList(),
      ];
    },
    large() {
      return [
        split([
          column([
            grid(3, [
              stat('Requests', '12.4k', { icon: 'arrow.up.arrow.down', trend: 'up' }),
              stat('Errors', 0.4, { unit: '%', tone: 'good' }),
              stat('Latency', 182, { unit: 'ms', tone: 'warn', trend: 'down' }),
            ]),
            section('Charts', [
              chart(wave, { labels: ['1 h ago', 'now'] }),
            ]),
            section('Tones', [row(tones.map((tone) => badge(tone, { tone })), { spacing: 'tight' })], { priority: 'detail' }),
          ], { spacing: 'normal' }),
          column([
            section('Lists', [sampleList()]),
            section('Controls', [
              segmented(['Day', 'Week', 'Month'], choice, 'choose'),
              toggle('Notify on change', isOn, 'toggle', { icon: 'bell' }),
              slider(level, 'slide', { label: `Threshold ${Math.round(level * 100)}%`, icon: 'slider.horizontal.3' }),
              grid(2, [
                button('Primary', 'noop', { style: 'primary', icon: 'play.fill' }),
                button('Delete', 'noop', { style: 'destructive', icon: 'trash' }),
              ]),
            ]),
          ], { spacing: 'normal' }),
        ], { weights: [1.1, 1] }),
      ];
    },
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

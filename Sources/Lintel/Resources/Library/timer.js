const presets = { '5 min': 300, '15 min': 900, '25 min': 1500, '50 min': 3000 };

function state(host) {
  const saved = host.storage.get('timer', { duration: 1500, endsAt: null, remaining: 1500 });
  const isRunning = saved.endsAt !== null;
  const remaining = isRunning ? Math.max(Math.round((saved.endsAt - Date.now()) / 1000), 0) : saved.remaining;
  return { duration: saved.duration, endsAt: saved.endsAt, remaining, isRunning };
}

function finishIfDue(host, timer) {
  if (!timer.isRunning || timer.remaining > 0) return timer;
  host.storage.set('timer', { duration: timer.duration, endsAt: null, remaining: timer.duration });
  host.notify('Timer finished', `${host.format.duration(timer.duration)} are up.`);
  return state(host);
}

defineModule({
  meta: {
    id: 'timer',
    title: 'Timer',
    icon: 'timer',
    summary: 'A focus timer that counts down in the bar or lives on your desktop as a widget.',
    pinned: false,
    order: 40,
    refreshSeconds: 1,
    panelRefreshSeconds: 1,
    defaultShape: 'compact',
    permissions: ['notify'],
  },
  chip(host) {
    const timer = finishIfDue(host, state(host));
    host.attention(timer.isRunning);
    if (!timer.isRunning && timer.remaining === timer.duration) return icon('timer');
    return row([
      ring(1 - timer.remaining / timer.duration, { tone: timer.isRunning ? 'accent' : 'secondary' }),
      text(host.format.timer(timer.remaining), { mono: true, tone: timer.isRunning ? 'primary' : 'secondary' }),
    ]);
  },
  widget(host) {
    const timer = finishIfDue(host, state(host));
    host.attention(timer.isRunning);
    const isFresh = !timer.isRunning && timer.remaining === timer.duration;
    const selected = Object.keys(presets).find((label) => presets[label] === timer.duration) || '';
    const primary = timer.isRunning
      ? button('Pause', 'pause', { icon: 'pause.fill', style: 'primary' })
      : button(isFresh ? 'Start' : 'Resume', 'start', { icon: 'play.fill', style: 'primary' });
    return [
      split([
        column([
          text(host.format.timer(timer.remaining), { role: 'display', mono: true }),
          text(timer.isRunning ? `Ends at ${host.format.time(timer.endsAt)}` : isFresh ? 'Ready' : 'Paused', { role: 'caption' }),
          progress(1 - timer.remaining / timer.duration),
        ], { spacing: 'tight' }),
        column([
          segmented(Object.keys(presets), selected, 'setDuration'),
          grid(2, [primary, button('Reset', 'reset', { icon: 'arrow.counterclockwise' })]),
        ], { spacing: 'normal' }),
      ], { weights: [1, 1.15] }),
    ];
  },
  actions: {
    start(host) {
      const timer = state(host);
      host.storage.set('timer', { duration: timer.duration, endsAt: Date.now() + timer.remaining * 1000, remaining: timer.remaining });
    },
    pause(host) {
      const timer = state(host);
      host.storage.set('timer', { duration: timer.duration, endsAt: null, remaining: timer.remaining });
    },
    reset(host) {
      const timer = state(host);
      host.storage.set('timer', { duration: timer.duration, endsAt: null, remaining: timer.duration });
    },
    setDuration(host, label) {
      const duration = presets[label] || 1500;
      host.storage.set('timer', { duration, endsAt: null, remaining: duration });
    },
  },
});

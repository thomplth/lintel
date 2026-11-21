function speaker(audio) {
  if (audio.muted || audio.volume === 0) return 'speaker.slash.fill';
  return audio.volume < 0.34 ? 'speaker.wave.1.fill' : audio.volume < 0.67 ? 'speaker.wave.2.fill' : 'speaker.wave.3.fill';
}

defineModule({
  meta: {
    id: 'sound',
    title: 'Sound',
    icon: 'speaker.wave.2.fill',
    summary: 'Output volume and mute.',
    pinned: false,
    order: 60,
    refreshSeconds: 2,
    panelRefreshSeconds: 1,
    sizes: ['chip', 'small', 'wide'],
    defaultSize: 'wide',
    permissions: ['audio'],
  },
  views: {
    chip(host) {
      const audio = host.audio();
      return icon(speaker(audio), { tone: audio.muted ? 'secondary' : undefined });
    },
    small(host) {
      const audio = host.audio();
      if (!audio.output) return [empty('speaker.slash.fill', 'No output')];
      return [
        column([
          row([
            icon(speaker(audio), { tone: audio.muted ? 'secondary' : 'accent', size: 'large' }),
            spacer(),
            text(audio.muted ? 'Muted' : host.format.percent(audio.volume), { role: 'title', mono: true }),
          ]),
          spacer(),
          slider(audio.volume, 'setVolume'),
          button(audio.muted ? 'Unmute' : 'Mute', 'setMuted', {
            icon: audio.muted ? 'speaker.wave.2.fill' : 'speaker.slash.fill',
            style: audio.muted ? 'primary' : 'secondary',
            payload: !audio.muted,
          }),
        ], { spacing: 'tight' }),
      ];
    },
    wide(host) {
      const audio = host.audio();
      if (!audio.output) return [empty('speaker.slash.fill', 'No output device')];
      return [
        slider(audio.volume, 'setVolume', { label: `Volume ${host.format.percent(audio.volume)}`, icon: speaker(audio) }),
        toggle('Mute', audio.muted, 'setMuted', { icon: 'speaker.slash.fill' }),
        keyValue('Output', audio.output),
      ];
    },
  },
  actions: {
    async setVolume(host, fraction) {
      await host.setVolume(fraction);
    },
    async setMuted(host, isMuted) {
      await host.setMuted(isMuted);
    },
  },
});

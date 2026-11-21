function statusTone(status) {
  if (status === 'failed') return 'bad';
  if (status === 'running') return 'info';
  if (status === 'paused') return 'secondary';
  return 'good';
}

function statusIcon(status) {
  if (status === 'failed') return 'exclamationmark.triangle.fill';
  if (status === 'running') return 'clock.arrow.circlepath';
  if (status === 'paused') return 'pause.fill';
  return 'checkmark.circle.fill';
}

function nextText(host, job) {
  if (job.status === 'running') return 'running';
  if (job.status === 'paused') return 'paused';
  if (!job.nextRunAt) return job.schedule;
  const secs = Math.max(0, Math.round((job.nextRunAt - Date.now()) / 1000));
  return secs <= 5 ? 'due now' : `in ${host.format.duration(secs)}`;
}

defineModule({
  meta: {
    id: 'jobs',
    title: 'Scheduled Jobs',
    icon: 'clock.arrow.circlepath',
    summary: 'Background jobs declared by your modules: status, next run, errors and manual triggers.',
    pinned: false,
    order: 65,
    refreshSeconds: 30,
    panelRefreshSeconds: 5,
    defaultShape: 'card',
    permissions: ['jobs'],
  },
  chip(host) {
    const jobs = host.allJobs();
    const failed = jobs.filter((job) => job.status === 'failed');
    const running = jobs.filter((job) => job.status === 'running');
    host.attention(failed.length > 0);
    if (failed.length > 0) {
      return row([icon('exclamationmark.triangle.fill', { tone: 'bad' }), text(`${failed.length} failed`, { tone: 'bad' })]);
    }
    if (running.length > 0) {
      return row([icon('clock.arrow.circlepath', { tone: 'info' }), text(`${running.length} running`, { tone: 'secondary' })]);
    }
    return row([
      icon('clock.arrow.circlepath', { tone: jobs.length > 0 ? undefined : 'secondary' }),
      text(jobs.length > 0 ? `${jobs.length} jobs` : 'no jobs', { mono: true, tone: 'secondary' }),
    ]);
  },
  widget(host) {
    const jobs = host.allJobs();
    if (jobs.length === 0) {
      return [empty('clock.arrow.circlepath', 'No scheduled jobs', {
        message: 'Any module that declares a jobs block appears here automatically.',
      })];
    }
    const failed = jobs.filter((job) => job.status === 'failed');
    const active = jobs.filter((job) => job.enabled);
    const rows = list(jobs.map((job) => {
      const subtitleParts = [job.moduleTitle, job.schedule];
      if (job.lastRunAt) subtitleParts.push(`last ${host.format.ago(job.lastRunAt)}`);
      if (job.lastError) subtitleParts.push(host.format.truncate(job.lastError, 48));
      return item(job.title, {
        subtitle: subtitleParts.join(' · '),
        icon: statusIcon(job.status),
        tone: statusTone(job.status),
        value: nextText(host, job),
        action: 'run',
        payload: job.key,
        accessoryIcon: job.enabled ? 'pause.fill' : 'play.fill',
        accessoryAction: 'toggle',
        accessoryLabel: job.enabled ? 'Pause' : 'Resume',
      });
    }));
    return [
      grid(2, [
        stat('Jobs', jobs.length, { icon: 'clock.arrow.circlepath', caption: `${active.length} active` }),
        stat('Failed', failed.length, {
          icon: failed.length > 0 ? 'exclamationmark.triangle.fill' : 'checkmark.circle.fill',
          tone: failed.length > 0 ? 'bad' : 'good',
          caption: failed.length > 0 ? 'needs attention' : 'all healthy',
        }),
      ]),
      section('All Jobs', [rows], { trailing: 'Click to run' }),
      ...(failed.length > 0 ? [
        section('Errors', failed.map((job) => note(`${job.title}: ${job.lastError}`, { tone: 'bad', icon: 'exclamationmark.triangle.fill' })), { elastic: true, priority: 'detail' }),
      ] : []),
    ];
  },
  actions: {
    async run(host, key) {
      if (!key) return;
      await host.jobs.run(key);
    },
    toggle(host, key) {
      if (!key) return;
      const job = host.allJobs().find((entry) => entry.key === key);
      if (job) host.jobs.setEnabled(key, !job.enabled);
    },
  },
});

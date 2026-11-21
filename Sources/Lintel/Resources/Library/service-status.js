const tones = { none: 'good', minor: 'warn', major: 'bad', critical: 'bad', maintenance: 'info' };
const componentTones = { operational: 'good', degraded_performance: 'warn', partial_outage: 'warn', major_outage: 'bad', under_maintenance: 'info' };

let summary = null, failure = null, loadedAt = 0;

async function load(host) {
  if (summary && Date.now() - loadedAt < 60 * 1000) return;
  try {
    summary = await host.fetchJSON('https://www.githubstatus.com/api/v2/summary.json');
    failure = null;
    loadedAt = Date.now();
  } catch (error) {
    failure = error.message;
  }
}

defineModule({
  meta: {
    id: 'service-status',
    title: 'GitHub Status',
    icon: 'checkmark.seal',
    summary: 'Whether GitHub is up: dot in the bar, service list and active incidents in a responsive widget.',
    pinned: false,
    order: 26,
    refreshSeconds: 120,
    defaultShape: 'card',
    permissions: ['www.githubstatus.com', 'notify'],
  },
  async chip(host) {
    const before = summary ? summary.status.indicator : null;
    await load(host);
    if (!summary) return row([dot('tertiary'), text('GitHub', { tone: 'secondary' })]);
    const indicator = summary.status.indicator;
    host.attention(indicator !== 'none');
    if (before === 'none' && indicator !== 'none') host.notify('GitHub status changed', summary.status.description);
    return row([dot(tones[indicator] || 'warn'), text('GitHub')]);
  },
  async widget(host) {
    await load(host);
    if (!summary) return [empty('wifi.slash', 'Cannot reach status', { message: failure || 'Still loading.', action: 'retry' })];
    const components = summary.components.filter((component) => !component.group && component.name.indexOf('Visit') < 0);
    const incidents = summary.incidents || [];
    const tone = tones[summary.status.indicator] || 'warn';
    return [
      row([dot(tone), text(summary.status.description, { role: 'title' })]),
      incidents.length > 0 ? section('Incidents', [
        list(incidents.map((incident) => item(host.format.truncate(incident.name, 44), {
          subtitle: `${incident.status} · ${host.format.ago(incident.updated_at)}`,
          icon: 'exclamationmark.triangle.fill',
          tone: tones[incident.impact] || 'warn',
          url: incident.shortlink,
        }))),
      ]) : null,
      section('Services', [
        list(components.map((component) => item(component.name, {
          icon: component.status === 'operational' ? 'checkmark.circle.fill' : 'exclamationmark.circle.fill',
          tone: componentTones[component.status] || 'warn',
          value: component.status === 'operational' ? undefined : component.status.replace(/_/g, ' '),
        }))),
      ], { trailing: host.format.ago(loadedAt), priority: 'supporting' }),
    ].filter(Boolean);
  },
  actions: {
    retry() {
      loadedAt = 0;
    },
  },
});

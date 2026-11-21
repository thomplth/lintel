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

function coreComponents() {
  return summary.components.filter((component) => !component.group && component.name.indexOf('Visit') < 0);
}

function serviceList(components, compact) {
  return list(components.slice(0, 12).map((component) => item(component.name, {
    icon: component.status === 'operational' ? 'checkmark.circle.fill' : 'exclamationmark.circle.fill',
    tone: componentTones[component.status] || 'warn',
    value: component.status === 'operational' ? undefined : component.status.replace(/_/g, ' '),
  })), { compact });
}

function unavailable() {
  return [empty('wifi.slash', 'Cannot reach status', { message: failure || 'Still loading.', action: 'retry' })];
}

defineModule({
  meta: {
    id: 'service-status',
    title: 'GitHub Status',
    icon: 'checkmark.seal',
    summary: 'Whether GitHub is up: dot in the bar, service grid and live page across widget sizes.',
    pinned: false,
    order: 26,
    refreshSeconds: 120,
    sizes: ['chip', 'small', 'wide', 'medium', 'large'],
    defaultSize: 'medium',
    permissions: ['www.githubstatus.com', 'notify'],
  },
  views: {
    async chip(host) {
      const before = summary ? summary.status.indicator : null;
      await load(host);
      if (!summary) return row([dot('tertiary'), text('GitHub', { tone: 'secondary' })]);
      const indicator = summary.status.indicator;
      host.attention(indicator !== 'none');
      if (before === 'none' && indicator !== 'none') host.notify('GitHub status changed', summary.status.description);
      return row([dot(tones[indicator] || 'warn'), text('GitHub')]);
    },
    async small(host) {
      await load(host);
      if (!summary) return unavailable();
      const tone = tones[summary.status.indicator] || 'warn';
      const incidents = summary.incidents || [];
      return [
        column([
          row([dot(tone), text('GitHub', { role: 'label', weight: 'semibold' }), spacer(), badge(incidents.length === 0 ? 'OK' : String(incidents.length), { tone })]),
          text(summary.status.description, { role: 'title', lines: 3 }),
          spacer(),
          text(`Updated ${host.format.ago(loadedAt)}`, { role: 'caption', tone: 'tertiary' }),
        ], { spacing: 'tight' }),
      ];
    },
    async wide(host) {
      await load(host);
      if (!summary) return unavailable();
      const tone = tones[summary.status.indicator] || 'warn';
      const components = coreComponents();
      return [
        split([
          column([
            row([dot(tone), text('GitHub', { role: 'label', weight: 'semibold' })]),
            text(summary.status.description, { role: 'title', lines: 3 }),
            spacer(),
            text(`Updated ${host.format.ago(loadedAt)}`, { role: 'caption', tone: 'tertiary' }),
          ], { spacing: 'tight' }),
          section('Services', [serviceList(components, true)]),
        ], { weights: [0.95, 1.25] }),
      ];
    },
    async medium(host) {
      await load(host);
      if (!summary) return unavailable();
      const components = coreComponents();
      const incidents = summary.incidents || [];
      return [
        row([dot(tones[summary.status.indicator] || 'warn'), text(summary.status.description, { role: 'title' })]),
        incidents.length > 0 ? section('Incidents', [
          list(incidents.slice(0, 4).map((incident) => item(host.format.truncate(incident.name, 44), {
            subtitle: `${incident.status} · ${host.format.ago(incident.updated_at)}`, icon: 'exclamationmark.triangle.fill',
            tone: tones[incident.impact] || 'warn', url: incident.shortlink,
          })), { compact: true }),
        ]) : null,
        section('Services', [serviceList(components, true)]),
      ].filter(Boolean);
    },
    async large(host) {
      await load(host);
      if (!summary) return unavailable();
      const components = coreComponents();
      const incidents = summary.incidents || [];
      return [
        split([
          column([
            row([dot(tones[summary.status.indicator] || 'warn'), text(summary.status.description, { role: 'title' })]),
            incidents.length > 0 ? section('Incidents', [
              list(incidents.slice(0, 4).map((incident) => item(host.format.truncate(incident.name, 44), {
                subtitle: `${incident.status} · ${host.format.ago(incident.updated_at)}`, icon: 'exclamationmark.triangle.fill',
                tone: tones[incident.impact] || 'warn', url: incident.shortlink,
              }))),
            ]) : null,
            section('Services', [serviceList(components, true)]),
          ].filter(Boolean), { spacing: 'normal' }),
          section('Live status page', [
            web('https://www.githubstatus.com', { height: 'fill', selector: '.components-section', zoom: 0.7 }),
          ]),
        ], { weights: [1, 1.15] }),
      ];
    },
  },
  actions: {
    retry() {
      loadedAt = 0;
    },
  },
});

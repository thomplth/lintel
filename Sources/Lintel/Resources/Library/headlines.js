let stories = [], failure = null, loadedAt = 0;

async function load(host) {
  if (stories.length > 0 && Date.now() - loadedAt < 10 * 60 * 1000) return;
  try {
    const found = await host.fetchJSON('https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=16');
    stories = found.hits.map((hit) => ({
      title: hit.title, points: hit.points, comments: hit.num_comments, at: hit.created_at,
      url: `https://news.ycombinator.com/item?id=${hit.objectID}`,
    }));
    failure = null;
    loadedAt = Date.now();
  } catch (error) {
    failure = error.message;
  }
}

function storyRows(host, slice, compact) {
  return list(slice.map((story) => item(story.title, {
    subtitle: `${story.points} pts · ${story.comments} comments · ${host.format.ago(story.at)}`,
    value: compact ? `${story.points}` : undefined,
    url: story.url,
  })), { compact });
}

function unavailable() {
  return [empty('wifi.slash', 'Cannot load front page', { message: failure || 'Still loading.', action: 'retry' })];
}

defineModule({
  meta: {
    id: 'headlines',
    title: 'Hacker News',
    icon: 'newspaper',
    summary: 'Top story in the bar; adaptive Hacker News front page across widget sizes.',
    pinned: false,
    order: 15,
    refreshSeconds: 600,
    sizes: ['chip', 'small', 'wide', 'medium', 'large', 'tall'],
    defaultSize: 'medium',
    permissions: ['hn.algolia.com'],
  },
  views: {
    async chip(host) {
      await load(host);
      if (stories.length === 0) return icon('newspaper', { tone: 'secondary' });
      return row([icon('newspaper'), text(host.format.truncate(stories[0].title, 28))]);
    },
    async small(host) {
      await load(host);
      if (stories.length === 0) return unavailable();
      const top = stories[0];
      return [
        column([
          row([icon('newspaper', { tone: 'orange' }), text('Hacker News', { role: 'caption', weight: 'semibold' }), spacer(), badge('#1', { tone: 'orange' })]),
          text(top.title, { role: 'label', weight: 'medium', lines: 4 }),
          spacer(),
          row([
            text(`${top.points} pts`, { role: 'caption', mono: true, tone: 'secondary' }),
            spacer(),
            button('Open', { url: top.url, style: 'plain', icon: 'safari' }),
          ]),
        ], { spacing: 'tight' }),
      ];
    },
    async wide(host) {
      await load(host);
      if (stories.length === 0) return unavailable();
      return [
        section('Hacker News', [storyRows(host, stories.slice(0, 8), true)], { trailing: host.format.ago(loadedAt) }),
      ];
    },
    async medium(host) {
      await load(host);
      if (stories.length === 0) return unavailable();
      return [
        section('Front page', [storyRows(host, stories.slice(0, 12), false)], { trailing: host.format.ago(loadedAt) }),
        failure ? note(`Last good reading. ${failure}`, { tone: 'warn' }) : null,
      ].filter(Boolean);
    },
    async large(host) {
      await load(host);
      if (stories.length === 0) return unavailable();
      const left = stories.slice(0, 8);
      const right = stories.slice(8, 16);
      return [
        split([
          section('Top stories', [storyRows(host, left, false)]),
          section('More front page', [storyRows(host, right, false)], { trailing: host.format.ago(loadedAt) }),
        ]),
      ];
    },
    async tall(host) {
      await load(host);
      if (stories.length === 0) return unavailable();
      return [
        section('Hacker News', [storyRows(host, stories.slice(0, 16), false)], { trailing: host.format.ago(loadedAt) }),
        failure ? note(`Showing the last good reading. ${failure}`, { tone: 'warn' }) : note(`Updated ${host.format.ago(loadedAt)}`),
      ];
    },
  },
  actions: {
    retry() {
      loadedAt = 0;
    },
  },
});

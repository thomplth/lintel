let stories = [], failure = null, loadedAt = 0;

async function load(host) {
  if (stories.length > 0 && Date.now() - loadedAt < 10 * 60 * 1000) return;
  try {
    const found = await host.fetchJSON('https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=24');
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

defineModule({
  meta: {
    id: 'headlines',
    title: 'Hacker News',
    icon: 'newspaper',
    summary: 'Top story in the bar; adaptive Hacker News front page in a responsive widget.',
    pinned: false,
    order: 15,
    refreshSeconds: 600,
    defaultShape: 'card',
    permissions: ['hn.algolia.com'],
  },
  async chip(host) {
    await load(host);
    if (stories.length === 0) return icon('newspaper', { tone: 'secondary' });
    return row([icon('newspaper'), text(host.format.truncate(stories[0].title, 28))]);
  },
  async widget(host) {
    await load(host);
    if (stories.length === 0) {
      return [empty('wifi.slash', 'Cannot load front page', { message: failure || 'Still loading.', action: 'retry' })];
    }
    return [
      section('Hacker News', [
        list(stories.map((story) => item(story.title, {
          subtitle: `${story.points} pts · ${story.comments} comments · ${host.format.ago(story.at)}`,
          value: `${story.points}`,
          url: story.url,
        }))),
      ], { trailing: host.format.ago(loadedAt) }),
      failure ? note(`Showing last good reading. ${failure}`, { tone: 'warn', priority: 'detail' }) : null,
    ].filter(Boolean);
  },
  actions: {
    retry() {
      loadedAt = 0;
    },
  },
});

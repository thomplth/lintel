let stories = [], failure = null, loadedAt = 0;

async function load(host) {
  if (stories.length > 0 && Date.now() - loadedAt < 10 * 60 * 1000) return;
  try {
    const found = await host.fetchJSON('https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=12');
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
    summary: 'The top story in the bar and the front page in the panel.',
    pinned: false,
    order: 15,
    refreshSeconds: 600,
    panelWidth: 'large',
    permissions: ['hn.algolia.com'],
  },
  async render(host) {
    await load(host);
    if (stories.length === 0) return icon('newspaper', { tone: 'secondary' });
    return row([icon('newspaper'), text(host.format.truncate(stories[0].title, 28))]);
  },
  async panel(host) {
    await load(host);
    if (stories.length === 0) {
      return [empty('wifi.slash', 'Cannot load the front page', { message: failure || 'Still loading.', action: 'retry' })];
    }
    return [
      list(stories.slice(0, 10).map((story) => item(host.format.truncate(story.title, 62), {
        subtitle: `${story.points} points · ${story.comments} comments · ${host.format.ago(story.at)}`, url: story.url,
      }))),
      failure ? note(`Showing the last good reading. ${failure}`, { tone: 'warn' }) : note(`Updated ${host.format.ago(loadedAt)}`),
    ];
  },
  actions: {
    retry() {
      loadedAt = 0;
    },
  },
});

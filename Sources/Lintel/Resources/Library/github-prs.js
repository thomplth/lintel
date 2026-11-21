let waiting = [], mine = [], failure = null, loadedAt = 0;

async function search(host, filter) {
  const result = await host.exec('gh', ['search', 'prs', filter, '--state=open', '--limit', '20',
    '--json', 'title,url,number,repository,updatedAt,isDraft']);
  if (result.status !== 0) throw new Error(result.stderr.trim().split('\n').pop() || 'gh failed');
  return JSON.parse(result.stdout);
}

async function load(host) {
  if (Date.now() - loadedAt < 120 * 1000) return;
  try {
    waiting = await search(host, '--review-requested=@me');
    mine = await search(host, '--author=@me');
    failure = null;
  } catch (error) {
    failure = error.message;
  }
  loadedAt = Date.now();
}

function rows(host, pulls) {
  return list(pulls.slice(0, 20).map((pull) => item(host.format.truncate(pull.title, 48), {
    subtitle: `${pull.repository.nameWithOwner} #${pull.number} · ${host.format.ago(pull.updatedAt)}`,
    icon: pull.isDraft ? 'pencil' : 'arrow.triangle.pull',
    url: pull.url,
  })));
}

defineModule({
  meta: {
    id: 'github-prs',
    title: 'Pull Requests',
    icon: 'arrow.triangle.pull',
    summary: 'Open pull requests waiting for your review and your own in a responsive widget.',
    pinned: false,
    order: 25,
    refreshSeconds: 180,
    defaultShape: 'card',
    permissions: ['exec:gh'],
  },
  async chip(host) {
    await load(host);
    const seen = new Set(host.storage.get('seenReviewRequests', []));
    const unseen = waiting.filter((pull) => !seen.has(pull.url));
    host.attention(!failure && unseen.length > 0);
    if (failure) return row([icon('arrow.triangle.pull', { tone: 'secondary' }), icon('exclamationmark.triangle.fill', { tone: 'warn' })]);
    return waiting.length === 0
      ? icon('arrow.triangle.pull')
      : row([icon('arrow.triangle.pull'), badge(waiting.length, { tone: 'warn' })]);
  },
  async widget(host) {
    await load(host);
    if (failure) {
      return [empty('exclamationmark.triangle.fill', 'GitHub CLI failed', {
        message: `${failure}. Check that gh is installed and signed in (gh auth login).`, action: 'retry',
      })];
    }
    host.storage.set('seenReviewRequests', waiting.map((pull) => pull.url));
    if (waiting.length === 0 && mine.length === 0) {
      return [empty('checkmark.circle.fill', 'All clear', { message: 'No open pull requests involve you.' })];
    }
    return [
      grid(2, [
        stat('To review', waiting.length, { tone: waiting.length > 0 ? 'warn' : undefined }),
        stat('Yours open', mine.length),
      ]),
      split([
        section('Waiting for review', [
          waiting.length > 0 ? rows(host, waiting) : empty('checkmark.circle.fill', 'None waiting'),
        ], { trailing: String(waiting.length) }),
        section('Yours', [
          mine.length > 0 ? rows(host, mine) : empty('arrow.triangle.pull', 'No open PRs'),
        ], { trailing: String(mine.length), priority: 'supporting' }),
      ]),
      note(`Updated ${host.format.ago(loadedAt)}`, { priority: 'detail' }),
    ];
  },
  actions: {
    retry() {
      loadedAt = 0;
    },
  },
});

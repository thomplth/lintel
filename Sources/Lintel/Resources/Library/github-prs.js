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

function rows(host, pulls, compact) {
  return list(pulls.slice(0, 15).map((pull) => item(host.format.truncate(pull.title, 48), {
    subtitle: `${pull.repository.nameWithOwner} #${pull.number} · ${host.format.ago(pull.updatedAt)}`,
    icon: pull.isDraft ? 'pencil' : 'arrow.triangle.pull',
    url: pull.url,
  })), { compact });
}

function failedView() {
  return [empty('exclamationmark.triangle.fill', 'GitHub CLI failed', {
    message: `${failure}. Check that gh is installed and signed in (gh auth login).`, action: 'retry',
  })];
}

function clearView() {
  return [empty('checkmark.circle.fill', 'All clear', { message: 'No open pull requests involve you.' })];
}

defineModule({
  meta: {
    id: 'github-prs',
    title: 'Pull Requests',
    icon: 'arrow.triangle.pull',
    summary: 'Open pull requests waiting for your review and your own across every widget size.',
    pinned: false,
    order: 25,
    refreshSeconds: 180,
    sizes: ['chip', 'small', 'wide', 'medium', 'large', 'tall'],
    defaultSize: 'medium',
    permissions: ['exec:gh'],
  },
  views: {
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
    async small(host) {
      await load(host);
      if (failure) return failedView();
      if (waiting.length === 0 && mine.length === 0) return clearView();
      return [
        grid(2, [
          stat('Review', waiting.length, { tone: waiting.length > 0 ? 'warn' : undefined }),
          stat('Mine', mine.length),
        ]),
        waiting.length > 0 ? rows(host, waiting, true) : rows(host, mine, true),
      ];
    },
    async wide(host) {
      await load(host);
      if (failure) return failedView();
      host.storage.set('seenReviewRequests', waiting.map((pull) => pull.url));
      if (waiting.length === 0 && mine.length === 0) return clearView();
      return [
        split([
          column([
            stat('To review', waiting.length, { icon: 'arrow.triangle.pull', tone: waiting.length > 0 ? 'warn' : undefined }),
            keyValue('Yours open', String(mine.length), { mono: true }),
          ], { spacing: 'tight' }),
          section(waiting.length > 0 ? 'Waiting for review' : 'Yours', [
            rows(host, waiting.length > 0 ? waiting : mine, true),
          ]),
        ], { weights: [0.85, 1.4] }),
      ];
    },
    async medium(host) {
      await load(host);
      if (failure) return failedView();
      host.storage.set('seenReviewRequests', waiting.map((pull) => pull.url));
      if (waiting.length === 0 && mine.length === 0) return clearView();
      return [
        grid(2, [
          stat('To review', waiting.length, { tone: waiting.length > 0 ? 'warn' : undefined }),
          stat('Yours open', mine.length),
        ]),
        waiting.length > 0 ? section('Waiting for your review', [rows(host, waiting, true)], { trailing: String(waiting.length) }) : null,
        mine.length > 0 ? section('Yours', [rows(host, mine, true)], { trailing: String(mine.length), priority: 'supporting' }) : null,
      ].filter(Boolean);
    },
    async large(host) {
      await load(host);
      if (failure) return failedView();
      host.storage.set('seenReviewRequests', waiting.map((pull) => pull.url));
      if (waiting.length === 0 && mine.length === 0) return clearView();
      return [
        split([
          section('Waiting for your review', [
            waiting.length > 0 ? rows(host, waiting, false) : empty('checkmark.circle.fill', 'None waiting'),
          ], { trailing: String(waiting.length) }),
          section('Yours', [
            mine.length > 0 ? rows(host, mine, false) : empty('arrow.triangle.pull', 'No open PRs'),
          ], { trailing: String(mine.length) }),
        ]),
      ];
    },
    async tall(host) {
      await load(host);
      if (failure) return failedView();
      host.storage.set('seenReviewRequests', waiting.map((pull) => pull.url));
      if (waiting.length === 0 && mine.length === 0) return clearView();
      return [
        grid(2, [
          stat('To review', waiting.length, { tone: waiting.length > 0 ? 'warn' : undefined }),
          stat('Yours open', mine.length),
        ]),
        waiting.length > 0 ? section('Waiting for your review', [rows(host, waiting, false)], { trailing: String(waiting.length) }) : null,
        mine.length > 0 ? section('Yours', [rows(host, mine, false)], { trailing: String(mine.length), priority: 'supporting' }) : null,
        note(`Updated ${host.format.ago(loadedAt)}`),
      ].filter(Boolean);
    },
  },
  actions: {
    retry() {
      loadedAt = 0;
    },
  },
});

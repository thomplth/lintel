const REFRESH_OPTIONS = { '15s': 15, '30s': 30, '60s': 60, '2m': 120 };
const STATUS_OPTIONS = ['Unreviewed', 'Needs approval', 'All'];
const SCOPE_OPTIONS = ['Direct + Team', 'Direct only'];
const REPO_MODES = ['All repos', 'Only selected', 'Exclude'];
const KNOWN_BOTS = new Set([
  'github-actions', 'dependabot', 'renovate', 'coderabbitai', 'copilot',
  'copilot-pull-request-reviewer', 'linear', 'vercel', 'netlify',
  'mergify', 'graphite-app', 'goodnotes-pr-creator',
]);

const PR_FIELDS = `
  number
  title
  url
  isDraft
  updatedAt
  createdAt
  additions
  deletions
  changedFiles
  reviewDecision
  mergeable
  mergeStateStatus
  repository { nameWithOwner name }
  author { __typename login }
  assignees(first: 10) { nodes { login } }
  reviewRequests(first: 15) {
    nodes {
      requestedReviewer {
        __typename
        ... on User { login }
        ... on Team { slug combinedSlug }
      }
    }
  }
  latestOpinionatedReviews(first: 20) {
    nodes { state submittedAt author { __typename login } }
  }
  reviews(first: 20) {
    nodes { state submittedAt author { __typename login } }
  }
  commits(last: 1) {
    nodes { commit { statusCheckRollup { state } } }
  }
`;

const REVIEWS_QUERY = `query {
  viewer { login }
  reviewRequested: search(query: "is:pr is:open review-requested:@me", type: ISSUE, first: 40) {
    nodes { ... on PullRequest { ${PR_FIELDS} } }
  }
  assigned: search(query: "is:pr is:open assignee:@me -author:@me", type: ISSUE, first: 20) {
    nodes { ... on PullRequest { ${PR_FIELDS} } }
  }
}`;

let pulls = [], viewerLogin = '', failure = null, loadedAt = 0, hasLoaded = false;
let cachedToken = null, knownRepos = [], notifiedUrls = new Set(), inflight = null;

function config(host) {
  const statusFilter = host.storage.get('statusFilter', 'Unreviewed');
  const scope = host.storage.get('scope', 'Direct + Team');
  const repoMode = host.storage.get('repoMode', 'All repos');
  const refreshLabel = host.storage.get('refreshLabel', '15s');
  return {
    statusFilter: STATUS_OPTIONS.includes(statusFilter) ? statusFilter : 'Unreviewed',
    scope: SCOPE_OPTIONS.includes(scope) ? scope : 'Direct + Team',
    includeDrafts: !!host.storage.get('includeDrafts', false),
    ignoreBots: host.storage.get('ignoreBots', true) !== false,
    repoMode: REPO_MODES.includes(repoMode) ? repoMode : 'All repos',
    selectedRepos: (host.storage.get('selectedRepos', []) || []).filter((r) => typeof r === 'string' && r.includes('/')),
    refreshLabel: REFRESH_OPTIONS[refreshLabel] ? refreshLabel : '15s',
    refreshSeconds: REFRESH_OPTIONS[refreshLabel] || 15,
    notifyNew: !!host.storage.get('notifyNew', false),
  };
}

function isBotAuthor(author) {
  if (!author || !author.login) return true;
  if (author.__typename === 'Bot') return true;
  const login = author.login.toLowerCase();
  return login.endsWith('[bot]') || KNOWN_BOTS.has(login);
}

async function resolveToken(host, forceRefresh) {
  if (cachedToken && !forceRefresh) return cachedToken;
  const result = await host.exec('gh', ['auth', 'token']);
  if (result.status !== 0) {
    throw new Error((result.stderr || '').trim().split('\n').pop() || 'gh auth token failed');
  }
  const token = (result.stdout || '').trim();
  if (!token) throw new Error('No GitHub token found');
  cachedToken = token;
  return token;
}

async function queryGitHub(host, query) {
  let token = await resolveToken(host, false);
  const run = (tok) => host.fetchJSON('https://api.github.com/graphql', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${tok}`,
      'Content-Type': 'application/json',
      'User-Agent': 'Lintel',
    },
    body: { query },
  });
  let response;
  try {
    response = await run(token);
  } catch (error) {
    if (String(error && error.message || '').includes('HTTP 401')) {
      cachedToken = null;
      token = await resolveToken(host, true);
      response = await run(token);
    } else {
      throw error;
    }
  }
  if (response && Array.isArray(response.errors) && response.errors.length > 0 && !response.data) {
    throw new Error(response.errors[0].message || 'GitHub GraphQL error');
  }
  return response && response.data ? response.data : {};
}

async function load(host, force) {
  const cfg = config(host);
  if (!force && hasLoaded && Date.now() - loadedAt < cfg.refreshSeconds * 1000) return;
  if (inflight) return inflight;
  inflight = (async () => {
    try {
      const data = await queryGitHub(host, REVIEWS_QUERY);
      viewerLogin = (data.viewer && data.viewer.login) || viewerLogin;
      const requestedNodes = (data.reviewRequested && data.reviewRequested.nodes) || [];
      const assignedNodes = (data.assigned && data.assigned.nodes) || [];
      const byUrl = new Map();
      for (const node of [...requestedNodes, ...assignedNodes]) {
        if (node && node.url && node.repository && node.repository.nameWithOwner) {
          byUrl.set(node.url, node);
        }
      }
      pulls = Array.from(byUrl.values());
      const repos = new Set(knownRepos);
      for (const pr of pulls) repos.add(pr.repository.nameWithOwner);
      knownRepos = Array.from(repos).sort((a, b) => a.localeCompare(b));
      failure = null;
      hasLoaded = true;
      loadedAt = Date.now();
    } catch (error) {
      failure = error && error.message ? error.message : String(error);
      if (!hasLoaded) loadedAt = Date.now();
    }
  })().finally(() => { inflight = null; });
  return inflight;
}

function analyzePull(pr, viewer, ignoreBots) {
  const viewerLower = (viewer || '').toLowerCase();
  const authorLogin = (pr.author && pr.author.login) || 'unknown';
  const authorLower = authorLogin.toLowerCase();

  const requestNodes = (pr.reviewRequests && pr.reviewRequests.nodes) || [];
  const assigneeNodes = (pr.assignees && pr.assignees.nodes) || [];
  let directRequested = false;
  const teams = [];
  for (const req of requestNodes) {
    const rev = req && req.requestedReviewer;
    if (!rev) continue;
    if (rev.__typename === 'User' && rev.login && rev.login.toLowerCase() === viewerLower) {
      directRequested = true;
    } else if (rev.__typename === 'Team' && (rev.slug || rev.combinedSlug)) {
      teams.push(rev.slug || rev.combinedSlug);
    }
  }
  const isAssigned = assigneeNodes.some((a) => a && a.login && a.login.toLowerCase() === viewerLower);
  const isDirect = directRequested || isAssigned;

  const isOtherReviewer = (author) => {
    if (!author || !author.login) return false;
    const lower = author.login.toLowerCase();
    if (lower === authorLower || lower === viewerLower) return false;
    if (ignoreBots && isBotAuthor(author)) return false;
    return true;
  };

  const approvedBy = [];
  const changesBy = [];
  const opinionated = (pr.latestOpinionatedReviews && pr.latestOpinionatedReviews.nodes) || [];
  for (const rev of opinionated) {
    if (!rev || !isOtherReviewer(rev.author)) continue;
    if (rev.state === 'APPROVED' && !approvedBy.includes(rev.author.login)) approvedBy.push(rev.author.login);
    if (rev.state === 'CHANGES_REQUESTED' && !changesBy.includes(rev.author.login)) changesBy.push(rev.author.login);
  }

  const commentedBy = [];
  const allReviews = (pr.reviews && pr.reviews.nodes) || [];
  for (const rev of allReviews) {
    if (!rev || !isOtherReviewer(rev.author)) continue;
    if (rev.state === 'COMMENTED' && !approvedBy.includes(rev.author.login) && !changesBy.includes(rev.author.login)) {
      if (!commentedBy.includes(rev.author.login)) commentedBy.push(rev.author.login);
    }
  }

  const isApproved = changesBy.length === 0 && (approvedBy.length > 0 || (!ignoreBots && pr.reviewDecision === 'APPROVED'));
  const hasChanges = changesBy.length > 0 || (!ignoreBots && pr.reviewDecision === 'CHANGES_REQUESTED');
  const alreadyReviewed = approvedBy.length > 0 || changesBy.length > 0 || commentedBy.length > 0 || isApproved || hasChanges;
  const hasConflict = pr.mergeable === 'CONFLICTING' || pr.mergeStateStatus === 'DIRTY';
  const commitNode = pr.commits && pr.commits.nodes && pr.commits.nodes[0];
  const ciState = (commitNode && commitNode.commit && commitNode.commit.statusCheckRollup && commitNode.commit.statusCheckRollup.state) || null;
  const ciFailed = ciState === 'FAILURE' || ciState === 'ERROR';

  return {
    pr,
    authorLogin,
    isDirect,
    teams,
    approvedBy,
    changesBy,
    commentedBy,
    isApproved,
    hasChanges,
    alreadyReviewed,
    hasConflict,
    ciFailed,
  };
}

function filteredPulls(host) {
  const cfg = config(host);
  const selected = new Set(cfg.selectedRepos);
  return pulls
    .map((pr) => analyzePull(pr, viewerLogin, cfg.ignoreBots))
    .filter((entry) => {
      if (!cfg.includeDrafts && entry.pr.isDraft) return false;
      if (cfg.scope === 'Direct only' && !entry.isDirect) return false;
      const repo = entry.pr.repository.nameWithOwner;
      if (cfg.repoMode === 'Only selected' && !selected.has(repo)) return false;
      if (cfg.repoMode === 'Exclude' && selected.has(repo)) return false;
      if (cfg.statusFilter === 'Unreviewed') return !entry.alreadyReviewed;
      if (cfg.statusFilter === 'Needs approval') return !entry.isApproved;
      return true;
    });
}

function groupByRepo(entries) {
  const byRepo = new Map();
  for (const entry of entries) {
    const key = entry.pr.repository.nameWithOwner;
    if (!byRepo.has(key)) byRepo.set(key, { nameWithOwner: key, shortName: entry.pr.repository.name || key.split('/').pop(), items: [] });
    byRepo.get(key).items.push(entry);
  }
  const groups = Array.from(byRepo.values());
  const owners = new Set(groups.map((g) => g.nameWithOwner.split('/')[0]));
  const singleOwner = owners.size <= 1;
  for (const group of groups) {
    group.title = singleOwner ? group.shortName : group.nameWithOwner;
    group.items.sort((a, b) => {
      if (a.isDirect !== b.isDirect) return a.isDirect ? -1 : 1;
      return new Date(b.pr.updatedAt).getTime() - new Date(a.pr.updatedAt).getTime();
    });
    group.latest = group.items.reduce((max, e) => Math.max(max, new Date(e.pr.updatedAt).getTime() || 0), 0);
  }
  groups.sort((a, b) => b.latest - a.latest || a.title.localeCompare(b.title));
  return groups;
}

function cleanTitle(raw) {
  let value = String(raw || '').trim();
  value = value.replace(/^(?:\[[^\]]+\]\s*)+/, '');
  value = value.replace(/^[A-Z][A-Z0-9_]+-\d+\s*(?:[:\-–—|]\s*|\s+)/, '');
  value = value.trim();
  if (!value) return String(raw || '').trim();
  return /^[a-z]/.test(value) && !/^[a-z]+(\([^)]+\))?:/.test(value)
    ? value.charAt(0).toUpperCase() + value.slice(1)
    : value;
}

function renderReviewItem(host, entry, showScopeHint) {
  const pr = entry.pr;
  let iconName = 'arrow.triangle.pull';
  let badgeLabel;
  let tone;

  if (entry.hasConflict) {
    iconName = 'exclamationmark.triangle.fill';
    badgeLabel = 'Conflict';
    tone = 'bad';
  } else if (entry.hasChanges) {
    iconName = 'xmark.circle.fill';
    badgeLabel = 'Changes';
    tone = 'warn';
  } else if (entry.isApproved) {
    iconName = 'checkmark.circle.fill';
    badgeLabel = 'Approved';
    tone = 'good';
  } else if (pr.isDraft) {
    iconName = 'pencil';
    badgeLabel = 'Draft';
    tone = 'secondary';
  } else if (entry.ciFailed) {
    iconName = 'exclamationmark.triangle.fill';
    badgeLabel = 'CI fail';
    tone = 'bad';
  } else if (entry.commentedBy.length > 0) {
    iconName = 'bubble.left';
    badgeLabel = 'Reviewed';
    tone = 'info';
  } else if (showScopeHint && entry.isDirect) {
    badgeLabel = 'Direct';
    tone = 'accent';
  }

  const parts = [`@${entry.authorLogin}`];
  if (entry.changesBy.length > 0) parts.push(`Changes (@${entry.changesBy[0]})`);
  else if (entry.approvedBy.length > 0) parts.push(`Approved (${entry.approvedBy.length})`);
  else if (entry.commentedBy.length > 0) parts.push(`Commented (@${entry.commentedBy[0]})`);
  if (entry.ciFailed && badgeLabel !== 'CI fail') parts.push('CI fail');
  if (typeof pr.additions === 'number' && typeof pr.deletions === 'number') {
    parts.push(`+${pr.additions} −${pr.deletions}`);
  }
  if (showScopeHint && !entry.isDirect && entry.teams.length > 0) parts.push(`@${entry.teams[0]}`);
  parts.push(`#${pr.number}`);
  parts.push(host.format.ago(pr.updatedAt));

  return item(cleanTitle(pr.title), {
    subtitle: parts.join(' · '),
    icon: iconName,
    badge: badgeLabel,
    tone,
    url: pr.url && pr.url.startsWith('https://') ? pr.url : undefined,
  });
}

function allCandidateRepos(host) {
  const set = new Set([...knownRepos, ...config(host).selectedRepos]);
  return Array.from(set).sort((a, b) => a.localeCompare(b));
}

defineModule({
  meta: {
    id: 'github-reviews',
    title: 'PR Reviews',
    icon: 'arrow.triangle.pull',
    summary: 'Incoming pull requests awaiting your review, grouped by repo with status and repo filters.',
    pinned: false,
    order: 25,
    refreshSeconds: 15,
    panelRefreshSeconds: 15,
    defaultShape: 'wide',
    permissions: ['api.github.com', 'exec:gh', 'notify'],
  },
  async chip(host) {
    await load(host, false);
    if (failure && !hasLoaded) {
      host.attention(false);
      return row([icon('arrow.triangle.pull', { tone: 'secondary' }), icon('exclamationmark.triangle.fill', { tone: 'warn' })]);
    }
    const cfg = config(host);
    const visible = filteredPulls(host);
    const seen = new Set(host.storage.get('seenReviewUrls', []));
    const unseen = visible.filter((entry) => !seen.has(entry.pr.url));
    host.attention(!failure && unseen.length > 0);
    if (cfg.notifyNew) {
      for (const entry of unseen) {
        if (!notifiedUrls.has(entry.pr.url)) {
          notifiedUrls.add(entry.pr.url);
          host.notify(`Review requested in ${entry.pr.repository.name}`, `#${entry.pr.number} ${entry.pr.title}`);
        }
      }
    }
    if (visible.length === 0) return icon('arrow.triangle.pull');
    const hasDirect = visible.some((entry) => entry.isDirect);
    return row([icon('arrow.triangle.pull'), badge(visible.length, { tone: hasDirect ? 'warn' : 'accent' })]);
  },
  async widget(host) {
    await load(host, false);
    if (failure && !hasLoaded) {
      return [empty('exclamationmark.triangle.fill', 'GitHub unavailable', {
        message: `${failure}. Check that gh is installed and signed in (gh auth login).`,
        action: 'refresh',
        actionLabel: 'Try again',
      })];
    }
    const cfg = config(host);
    const visible = filteredPulls(host);
    host.storage.set('seenReviewUrls', visible.map((entry) => entry.pr.url));
    for (const entry of visible) notifiedUrls.add(entry.pr.url);

    if (pulls.length === 0) {
      return [
        empty('checkmark.circle.fill', 'Review queue clear', {
          message: 'No open pull requests request your review.',
          action: 'refresh',
          actionLabel: 'Refresh',
        }),
        note(`Updated ${host.format.ago(loadedAt)} · ${cfg.refreshLabel} cadence`, { priority: 'detail' }),
      ];
    }

    if (visible.length === 0) {
      return [
        empty('checkmark.circle.fill', 'Nothing left to review', {
          message: `${pulls.length} open ${pulls.length === 1 ? 'PR is' : 'PRs are'} hidden by your filters.`,
          action: 'showAll',
          actionLabel: 'Show all open',
        }),
        note(`Filter: ${cfg.statusFilter} · ${cfg.scope} · Updated ${host.format.ago(loadedAt)}`, { priority: 'detail' }),
      ];
    }

    const groups = groupByRepo(visible);
    const directCount = visible.filter((entry) => entry.isDirect).length;
    const showScopeHint = cfg.scope === 'Direct + Team' && visible.some((e) => !e.isDirect);
    const hiddenCount = Math.max(0, pulls.length - visible.length);

    const blocks = [
      row([
        icon('arrow.triangle.pull', { tone: visible.length > 0 ? 'warn' : 'good' }),
        text(`${visible.length} ${visible.length === 1 ? 'PR' : 'PRs'}`, { role: 'label', tone: 'primary', weight: 'semibold', mono: true }),
        spacer(),
        ...(directCount > 0 ? [badge(`${directCount} direct`, { tone: 'accent' })] : []),
      ], { spacing: 'tight' }),
      ...groups.slice(0, 10).map((group) => section(group.title, [
        list(group.items.slice(0, 30).map((entry) => renderReviewItem(host, entry, showScopeHint))),
      ], { trailing: String(group.items.length) })),
    ];

    if (failure) {
      blocks.push(note(`Cached · ${failure}`, { tone: 'warn', icon: 'exclamationmark.triangle.fill', priority: 'detail' }));
    } else {
      const metaParts = [host.format.ago(loadedAt)];
      if (hiddenCount > 0) metaParts.push(`${hiddenCount} hidden`);
      blocks.push(note(metaParts.join(' · '), { priority: 'detail' }));
    }
    return blocks;
  },
  configure(host) {
    const cfg = config(host);
    const selected = new Set(cfg.selectedRepos);
    const repos = allCandidateRepos(host);
    const counts = new Map();
    for (const pr of pulls) {
      const name = pr.repository.nameWithOwner;
      counts.set(name, (counts.get(name) || 0) + 1);
    }
    const repoChildren = [
      segmented(REPO_MODES, cfg.repoMode, 'setRepoMode'),
      ...(repos.length > 0 ? [
        list(repos.slice(0, 30).map((repo) => {
          const isPicked = selected.has(repo);
          const count = counts.get(repo) || 0;
          return item(repo, {
            icon: isPicked ? 'checkmark.circle.fill' : 'circle',
            tone: isPicked ? 'accent' : undefined,
            value: count > 0 ? String(count) : undefined,
            action: 'toggleRepo',
            payload: repo,
          });
        })),
      ] : [note('Repos appear here once pull requests load, or add one below.')]),
      field('Add repo (owner/name)', 'addRepo', { icon: 'plus', suggest: 'suggestRepos' }),
    ];

    return [
      section('Review filter', [
        segmented(STATUS_OPTIONS, cfg.statusFilter, 'setStatusFilter'),
        segmented(SCOPE_OPTIONS, cfg.scope, 'setScope'),
        toggle('Include drafts', cfg.includeDrafts, 'setIncludeDrafts'),
        toggle('Ignore bot reviews', cfg.ignoreBots, 'setIgnoreBots'),
      ]),
      section('Repositories', repoChildren, { trailing: cfg.repoMode === 'All repos' ? 'All' : String(cfg.selectedRepos.length) }),
      section('Updates', [
        segmented(Object.keys(REFRESH_OPTIONS), cfg.refreshLabel, 'setRefresh'),
        toggle('Notify on new requests', cfg.notifyNew, 'setNotifyNew'),
        button('Refresh now', 'refresh', { icon: 'arrow.clockwise' }),
      ]),
    ];
  },
  actions: {
    setStatusFilter(host, value) {
      if (STATUS_OPTIONS.includes(value)) host.storage.set('statusFilter', value);
    },
    setScope(host, value) {
      if (SCOPE_OPTIONS.includes(value)) host.storage.set('scope', value);
    },
    setIncludeDrafts(host, isOn) {
      host.storage.set('includeDrafts', !!isOn);
    },
    setIgnoreBots(host, isOn) {
      host.storage.set('ignoreBots', !!isOn);
    },
    setRepoMode(host, value) {
      if (REPO_MODES.includes(value)) host.storage.set('repoMode', value);
    },
    toggleRepo(host, repo) {
      if (typeof repo !== 'string' || !repo.includes('/')) return;
      const cfg = config(host);
      const next = new Set(cfg.selectedRepos);
      if (next.has(repo)) next.delete(repo);
      else next.add(repo);
      host.storage.set('selectedRepos', Array.from(next).sort());
      if (cfg.repoMode === 'All repos' && next.size > 0) {
        host.storage.set('repoMode', 'Only selected');
      }
    },
    addRepo(host, raw) {
      const repo = String(raw || '').trim();
      if (!repo.includes('/')) return;
      const cfg = config(host);
      const next = new Set(cfg.selectedRepos);
      next.add(repo);
      host.storage.set('selectedRepos', Array.from(next).sort());
      if (cfg.repoMode === 'All repos') host.storage.set('repoMode', 'Only selected');
    },
    suggestRepos(host, typed) {
      const query = String(typed || '').trim().toLowerCase();
      if (!query) return [];
      const selected = new Set(config(host).selectedRepos);
      return allCandidateRepos(host)
        .filter((repo) => !selected.has(repo) && repo.toLowerCase().includes(query))
        .slice(0, 6)
        .map((repo) => ({ title: repo, value: repo }));
    },
    setRefresh(host, label) {
      if (REFRESH_OPTIONS[label]) host.storage.set('refreshLabel', label);
    },
    setNotifyNew(host, isOn) {
      host.storage.set('notifyNew', !!isOn);
    },
    showAll(host) {
      host.storage.set('statusFilter', 'All');
      host.storage.set('includeDrafts', true);
      host.storage.set('repoMode', 'All repos');
      host.storage.set('scope', 'Direct + Team');
    },
    async refresh(host) {
      loadedAt = 0;
      await load(host, true);
    },
  },
});

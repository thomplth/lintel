const REFRESH_OPTIONS = { '15s': 15, '30s': 30, '60s': 60, '2m': 120 };
const REPO_MODES = ['All repos', 'Only selected', 'Exclude'];
const KNOWN_BOTS = new Set([
  'github-actions', 'dependabot', 'renovate', 'coderabbitai', 'copilot',
  'copilot-pull-request-reviewer', 'linear', 'vercel', 'netlify',
  'mergify', 'graphite-app', 'goodnotes-pr-creator',
]);

const FAILED_CHECK_STATES = new Set(['FAILURE', 'ERROR', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'CANCELLED', 'STALE']);
const PENDING_CHECK_STATES = new Set(['IN_PROGRESS', 'QUEUED', 'PENDING', 'WAITING', 'EXPECTED']);

const MY_PRS_QUERY = `query {
  viewer { login }
  authored: search(query: "is:pr is:open author:@me", type: ISSUE, first: 40) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        isDraft
        updatedAt
        additions
        deletions
        baseRefName
        headRefName
        reviewDecision
        mergeable
        mergeStateStatus
        repository {
          nameWithOwner
          name
          defaultBranchRef { name }
        }
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
          nodes { state author { __typename login } }
        }
        reviews(first: 20) {
          nodes { state author { __typename login } }
        }
        reviewThreads(first: 50) {
          totalCount
          nodes { isResolved isOutdated }
        }
        comments { totalCount }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                state
                contexts {
                  totalCount
                  checkRunCountsByState { state count }
                  statusContextCountsByState { state count }
                }
              }
            }
          }
        }
      }
    }
  }
}`;

let pulls = [], viewerLogin = '', failure = null, loadedAt = 0, hasLoaded = false;
let cachedToken = null, knownRepos = [], previousStatus = new Map(), inflight = null;

function config(host) {
  const repoMode = host.storage.get('repoMode', 'All repos');
  const refreshLabel = host.storage.get('refreshLabel', '15s');
  return {
    includeDrafts: host.storage.get('includeDrafts', true) !== false,
    groupByStack: host.storage.get('groupByStack', true) !== false,
    ignoreBots: host.storage.get('ignoreBots', true) !== false,
    repoMode: REPO_MODES.includes(repoMode) ? repoMode : 'All repos',
    selectedRepos: (host.storage.get('selectedRepos', []) || []).filter((r) => typeof r === 'string' && r.includes('/')),
    refreshLabel: REFRESH_OPTIONS[refreshLabel] ? refreshLabel : '15s',
    refreshSeconds: REFRESH_OPTIONS[refreshLabel] || 15,
    notifyChanges: !!host.storage.get('notifyChanges', false),
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
      const data = await queryGitHub(host, MY_PRS_QUERY);
      viewerLogin = (data.viewer && data.viewer.login) || viewerLogin;
      const nodes = (data.authored && data.authored.nodes) || [];
      pulls = nodes.filter((node) => node && node.url && node.repository && node.repository.nameWithOwner);
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

function summarizeCI(pr) {
  const commitNode = pr.commits && pr.commits.nodes && pr.commits.nodes[0];
  const rollup = commitNode && commitNode.commit && commitNode.commit.statusCheckRollup;
  if (!rollup) return { state: 'none', passed: 0, failed: 0, pending: 0, total: 0, label: null };

  const contexts = rollup.contexts || {};
  const counts = [
    ...(contexts.checkRunCountsByState || []),
    ...(contexts.statusContextCountsByState || []),
  ];

  let passed = 0, failed = 0, pending = 0;
  for (const entry of counts) {
    if (!entry || !entry.count) continue;
    const st = String(entry.state || '').toUpperCase();
    if (st === 'SUCCESS') passed += entry.count;
    else if (FAILED_CHECK_STATES.has(st)) failed += entry.count;
    else if (PENDING_CHECK_STATES.has(st)) pending += entry.count;
  }

  const total = passed + failed + pending;
  const rollupState = String(rollup.state || '').toUpperCase();
  let state = 'none';
  if (failed > 0 || rollupState === 'FAILURE' || rollupState === 'ERROR') state = 'failed';
  else if (pending > 0 || rollupState === 'PENDING' || rollupState === 'EXPECTED') state = 'pending';
  else if (passed > 0 || rollupState === 'SUCCESS') state = 'passed';

  let label = null;
  if (state === 'failed') label = failed > 0 ? `CI ${failed} fail` : 'CI fail';
  else if (state === 'pending') label = total > 0 ? `CI ${passed}/${total} running` : 'CI running';
  else if (state === 'passed') label = total > 0 ? `CI ${passed}/${total}` : 'CI pass';

  return { state, passed, failed, pending, total, label };
}

function summarizePR(pr, viewer, ignoreBots) {
  const viewerLower = (viewer || '').toLowerCase();
  const isReviewer = (author) => {
    if (!author || !author.login) return false;
    if (author.login.toLowerCase() === viewerLower) return false;
    if (ignoreBots && isBotAuthor(author)) return false;
    return true;
  };

  const requested = [];
  for (const req of (pr.reviewRequests && pr.reviewRequests.nodes) || []) {
    const rev = req && req.requestedReviewer;
    if (!rev) continue;
    if (rev.__typename === 'User' && rev.login) requested.push(`@${rev.login}`);
    else if (rev.__typename === 'Team' && (rev.slug || rev.combinedSlug)) requested.push(`@${rev.slug || rev.combinedSlug}`);
  }

  const approvedBy = [];
  const changesBy = [];
  for (const rev of (pr.latestOpinionatedReviews && pr.latestOpinionatedReviews.nodes) || []) {
    if (!rev || !isReviewer(rev.author)) continue;
    if (rev.state === 'APPROVED' && !approvedBy.includes(rev.author.login)) approvedBy.push(rev.author.login);
    if (rev.state === 'CHANGES_REQUESTED' && !changesBy.includes(rev.author.login)) changesBy.push(rev.author.login);
  }

  const commentedBy = [];
  for (const rev of (pr.reviews && pr.reviews.nodes) || []) {
    if (!rev || !isReviewer(rev.author)) continue;
    if (rev.state === 'COMMENTED' && !approvedBy.includes(rev.author.login) && !changesBy.includes(rev.author.login)) {
      if (!commentedBy.includes(rev.author.login)) commentedBy.push(rev.author.login);
    }
  }

  const threadNodes = (pr.reviewThreads && pr.reviewThreads.nodes) || [];
  const unresolvedThreads = threadNodes.filter((t) => t && !t.isResolved).length;
  const totalComments = ((pr.comments && pr.comments.totalCount) || 0) + ((pr.reviewThreads && pr.reviewThreads.totalCount) || 0);
  const ci = summarizeCI(pr);
  const hasConflict = pr.mergeable === 'CONFLICTING' || pr.mergeStateStatus === 'DIRTY';
  const isBehind = pr.mergeStateStatus === 'BEHIND';
  const isApproved = changesBy.length === 0 && (approvedBy.length > 0 || (!ignoreBots && pr.reviewDecision === 'APPROVED'));
  const hasChanges = changesBy.length > 0 || (!ignoreBots && pr.reviewDecision === 'CHANGES_REQUESTED');
  const isBlocked = hasConflict || hasChanges || ci.state === 'failed';
  const isReady = !pr.isDraft && !hasConflict && !hasChanges && ci.state !== 'failed' && ci.state !== 'pending' && isApproved && unresolvedThreads === 0;

  let statusKey = 'open';
  if (hasConflict) statusKey = 'conflict';
  else if (hasChanges) statusKey = 'changes';
  else if (ci.state === 'failed') statusKey = 'ci-fail';
  else if (isReady) statusKey = 'ready';
  else if (isApproved) statusKey = 'approved';
  else if (pr.isDraft) statusKey = 'draft';
  else if (ci.state === 'pending') statusKey = 'ci-running';

  return {
    pr,
    requested,
    approvedBy,
    changesBy,
    commentedBy,
    unresolvedThreads,
    totalComments,
    ci,
    hasConflict,
    isBehind,
    isApproved,
    hasChanges,
    isBlocked,
    isReady,
    statusKey,
    defaultBranch: (pr.repository && pr.repository.defaultBranchRef && pr.repository.defaultBranchRef.name) || 'main',
  };
}

function filteredSummaries(host) {
  const cfg = config(host);
  const selected = new Set(cfg.selectedRepos);
  return pulls
    .filter((pr) => {
      if (!cfg.includeDrafts && pr.isDraft) return false;
      const repo = pr.repository.nameWithOwner;
      if (cfg.repoMode === 'Only selected' && !selected.has(repo)) return false;
      if (cfg.repoMode === 'Exclude' && selected.has(repo)) return false;
      return true;
    })
    .map((pr) => summarizePR(pr, viewerLogin, cfg.ignoreBots));
}

function buildStacks(summaries, groupByStack) {
  const byRepo = new Map();
  for (const entry of summaries) {
    const key = entry.pr.repository.nameWithOwner;
    if (!byRepo.has(key)) {
      byRepo.set(key, {
        nameWithOwner: key,
        shortName: entry.pr.repository.name || key.split('/').pop(),
        entries: [],
      });
    }
    byRepo.get(key).entries.push(entry);
  }
  const owners = new Set(Array.from(byRepo.keys()).map((k) => k.split('/')[0]));
  const singleOwner = owners.size <= 1;

  if (!groupByStack) {
    return Array.from(byRepo.values())
      .map((repo) => {
        repo.entries.sort((a, b) => new Date(b.pr.updatedAt).getTime() - new Date(a.pr.updatedAt).getTime());
        return {
          kind: 'repo',
          title: singleOwner ? repo.shortName : repo.nameWithOwner,
          trailing: String(repo.entries.length),
          latest: Math.max(...repo.entries.map((e) => new Date(e.pr.updatedAt).getTime() || 0)),
          rows: repo.entries.map((entry) => ({ entry, depth: 0, prefix: '', parentNumber: null, stackIndex: 0, stackSize: 1 })),
        };
      })
      .sort((a, b) => b.latest - a.latest || a.title.localeCompare(b.title));
  }

  const stackSections = [];
  const standaloneSections = [];

  for (const repo of byRepo.values()) {
    const repoTitle = singleOwner ? repo.shortName : repo.nameWithOwner;
    const byHead = new Map();
    for (const entry of repo.entries) {
      if (entry.pr.headRefName) byHead.set(entry.pr.headRefName, entry);
    }

    const childrenMap = new Map();
    const hasParent = new Set();
    for (const entry of repo.entries) {
      const parent = entry.pr.baseRefName ? byHead.get(entry.pr.baseRefName) : null;
      if (parent && parent.pr.number !== entry.pr.number) {
        if (!childrenMap.has(parent.pr.number)) childrenMap.set(parent.pr.number, []);
        childrenMap.get(parent.pr.number).push(entry);
        hasParent.add(entry.pr.number);
      }
    }

    const visited = new Set();
    const roots = repo.entries
      .filter((entry) => !hasParent.has(entry.pr.number))
      .sort((a, b) => a.pr.number - b.pr.number);

    // Ensure any cycle members are still surfaced safely.
    const allRoots = [...roots];
    for (const entry of repo.entries) {
      if (!allRoots.includes(entry)) allRoots.push(entry);
    }

    const standalone = [];

    for (const root of allRoots) {
      if (visited.has(root.pr.number)) continue;
      const nodes = [];
      const walk = (node, depth, parentNumber, isLastSibling) => {
        if (visited.has(node.pr.number)) return;
        visited.add(node.pr.number);
        const prefix = depth === 0 ? '' : (isLastSibling ? '└ ' : '├ ');
        nodes.push({ entry: node, depth, prefix, parentNumber });
        const kids = (childrenMap.get(node.pr.number) || [])
          .filter((k) => !visited.has(k.pr.number))
          .sort((a, b) => a.pr.number - b.pr.number);
        kids.forEach((child, idx) => {
          walk(child, depth + 1, node.pr.number, idx === kids.length - 1);
        });
      };
      walk(root, 0, null, true);

      if (nodes.length >= 2) {
        const size = nodes.length;
        const rows = nodes.map((n, idx) => ({ ...n, stackIndex: idx + 1, stackSize: size }));
        const latest = Math.max(...rows.map((r) => new Date(r.entry.pr.updatedAt).getTime() || 0));
        stackSections.push({
          kind: 'stack',
          title: repoTitle,
          trailing: `Stack ${size}`,
          latest,
          rows,
        });
      } else {
        standalone.push(nodes[0]);
      }
    }

    if (standalone.length > 0) {
      standalone.sort((a, b) => new Date(b.entry.pr.updatedAt).getTime() - new Date(a.entry.pr.updatedAt).getTime());
      standaloneSections.push({
        kind: 'repo',
        title: repoTitle,
        trailing: String(standalone.length),
        latest: Math.max(...standalone.map((r) => new Date(r.entry.pr.updatedAt).getTime() || 0)),
        rows: standalone.map((n) => ({ ...n, stackIndex: 0, stackSize: 1 })),
      });
    }
  }

  stackSections.sort((a, b) => b.latest - a.latest || a.title.localeCompare(b.title));
  standaloneSections.sort((a, b) => b.latest - a.latest || a.title.localeCompare(b.title));
  return [...stackSections, ...standaloneSections];
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

function renderPRRow(host, rowInfo) {
  const { entry, prefix, parentNumber, stackIndex, stackSize } = rowInfo;
  const pr = entry.pr;
  const cleaned = cleanTitle(pr.title);
  const title = stackSize >= 2 && prefix ? `${prefix}${cleaned}` : cleaned;

  let iconName = 'arrow.triangle.branch';
  let badgeLabel;
  let tone;

  if (entry.hasConflict) {
    iconName = 'exclamationmark.triangle.fill';
    badgeLabel = 'Conflict';
    tone = 'bad';
  } else if (entry.hasChanges) {
    iconName = 'xmark.circle.fill';
    badgeLabel = 'Changes';
    tone = 'bad';
  } else if (entry.ci.state === 'failed') {
    iconName = 'xmark.circle.fill';
    badgeLabel = 'CI fail';
    tone = 'bad';
  } else if (entry.isReady) {
    iconName = 'checkmark.circle.fill';
    badgeLabel = 'Ready';
    tone = 'good';
  } else if (entry.isApproved) {
    iconName = 'checkmark.circle.fill';
    badgeLabel = 'Approved';
    tone = 'good';
  } else if (pr.isDraft) {
    iconName = 'pencil';
    badgeLabel = 'Draft';
    tone = 'secondary';
  } else if (entry.ci.state === 'pending') {
    iconName = 'clock';
    badgeLabel = 'CI running';
    tone = 'warn';
  } else if (entry.requested.length > 0) {
    iconName = 'arrow.triangle.branch';
    badgeLabel = 'Review';
    tone = 'accent';
  }

  const compactParts = [];
  const parts = [];
  let valueLabel;
  if (!badgeLabel && entry.ci.state === 'passed') {
    valueLabel = 'CI ok';
  }

  if (pr.isDraft && badgeLabel !== 'Draft') {
    parts.push('Draft');
    compactParts.push('Draft');
  }
  if (!entry.hasConflict && entry.isBehind) {
    parts.push('Behind');
    compactParts.push('Behind');
  }

  if (entry.changesBy.length > 0) {
    const label = entry.changesBy.length === 1 ? `Changes (@${entry.changesBy[0]})` : `Changes (${entry.changesBy.length})`;
    parts.push(label);
    compactParts.push(entry.changesBy.length === 1 ? `@${entry.changesBy[0]}` : `${entry.changesBy.length} changes`);
  } else if (entry.approvedBy.length > 0) {
    const label = entry.approvedBy.length === 1 ? `Approved (@${entry.approvedBy[0]})` : `Approved (${entry.approvedBy.length})`;
    parts.push(label);
    compactParts.push(label);
  } else if (entry.commentedBy.length > 0) {
    const label = entry.commentedBy.length === 1 ? `Commented (@${entry.commentedBy[0]})` : `Commented (${entry.commentedBy.length})`;
    parts.push(label);
    compactParts.push(label);
  }

  if (entry.requested.length > 0) {
    const shown = entry.requested.slice(0, 2).join(', ');
    const more = entry.requested.length > 2 ? ` +${entry.requested.length - 2}` : '';
    const req = badgeLabel === 'Review' ? `${shown}${more}` : `Req ${shown}${more}`;
    parts.push(req);
    compactParts.push(req);
  }

  if (entry.unresolvedThreads > 0) {
    const label = `${entry.unresolvedThreads} unresolved`;
    parts.push(label);
    compactParts.push(label);
  }

  if (entry.ci.label) {
    if (badgeLabel === 'CI fail') {
      if (entry.ci.failed > 1) {
        parts.push(`${entry.ci.failed} failed`);
        compactParts.push(`${entry.ci.failed} failed`);
      }
    } else if (badgeLabel === 'CI running') {
      if (entry.ci.total > 0) {
        parts.push(`${entry.ci.passed}/${entry.ci.total}`);
        compactParts.push(`${entry.ci.passed}/${entry.ci.total}`);
      }
    } else {
      parts.push(entry.ci.label);
      compactParts.push(entry.ci.label);
    }
  }

  if (entry.unresolvedThreads === 0 && entry.totalComments > 0 && entry.approvedBy.length === 0 && entry.changesBy.length === 0) {
    parts.push(`${entry.totalComments} cmt`);
    compactParts.push(`${entry.totalComments} cmt`);
  }

  if (!parentNumber && pr.baseRefName && pr.baseRefName !== entry.defaultBranch) {
    compactParts.push(`← ${pr.baseRefName}`);
  }

  const refPart = parentNumber
    ? `#${pr.number} ← #${parentNumber}`
    : (pr.baseRefName && pr.baseRefName !== entry.defaultBranch ? `#${pr.number} ← ${pr.baseRefName}` : `#${pr.number}`);
  if (stackSize >= 2) parts.push(`${stackIndex}/${stackSize}`);
  parts.push(refPart);

  const compactTitle = stackSize >= 2 && prefix ? `${prefix}#${pr.number}` : `#${pr.number}`;
  const compactSubtitle = compactParts.length > 0 ? compactParts.join(' · ') : host.format.ago(pr.updatedAt);

  return item(title, {
    subtitle: parts.join(' · '),
    compactTitle,
    compactSubtitle,
    icon: iconName,
    value: valueLabel,
    badge: badgeLabel,
    tone,
    url: pr.url && pr.url.startsWith('https://') ? pr.url : undefined,
  });
}

function maybeNotifyStatusChanges(host, summaries, enabled) {
  const nextStatus = new Map();
  for (const entry of summaries) {
    const key = entry.pr.url;
    const prev = previousStatus.get(key);
    nextStatus.set(key, entry.statusKey);
    if (!enabled || !prev || prev === entry.statusKey) continue;
    const labels = {
      ready: 'ready to merge',
      approved: 'approved',
      conflict: 'has merge conflicts',
      changes: 'changes requested',
      'ci-fail': 'CI failed',
    };
    if (labels[entry.statusKey]) {
      host.notify(`PR #${entry.pr.number} ${labels[entry.statusKey]}`, entry.pr.title);
    }
  }
  previousStatus = nextStatus;
}

function allCandidateRepos(host) {
  const set = new Set([...knownRepos, ...config(host).selectedRepos]);
  return Array.from(set).sort((a, b) => a.localeCompare(b));
}

defineModule({
  meta: {
    id: 'github-my-prs',
    title: 'My PRs',
    icon: 'arrow.triangle.branch',
    summary: 'Your open pull requests organized by PR stack, with review, CI, comment, and conflict status.',
    pinned: false,
    order: 26,
    refreshSeconds: 15,
    panelRefreshSeconds: 15,
    defaultShape: 'wide',
    permissions: ['api.github.com', 'exec:gh', 'notify'],
  },
  async chip(host) {
    await load(host, false);
    if (failure && !hasLoaded) {
      host.attention(false);
      return row([icon('arrow.triangle.branch', { tone: 'secondary' }), icon('exclamationmark.triangle.fill', { tone: 'warn' })]);
    }
    const cfg = config(host);
    const summaries = filteredSummaries(host);
    maybeNotifyStatusChanges(host, summaries, cfg.notifyChanges);

    const blockedCount = summaries.filter((e) => e.isBlocked).length;
    const readyCount = summaries.filter((e) => e.isReady).length;
    host.attention(!failure && blockedCount > 0);

    if (summaries.length === 0) return icon('arrow.triangle.branch');
    const tone = blockedCount > 0 ? 'bad' : readyCount > 0 ? 'good' : 'accent';
    return row([
      icon('arrow.triangle.branch', { tone: blockedCount > 0 ? 'bad' : readyCount > 0 ? 'good' : undefined }),
      badge(summaries.length, { tone }),
    ]);
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
    const summaries = filteredSummaries(host);
    maybeNotifyStatusChanges(host, summaries, cfg.notifyChanges);

    if (pulls.length === 0) {
      return [
        empty('arrow.triangle.branch', 'No open pull requests', {
          message: 'Open pull requests you author will appear here grouped by stack.',
          action: 'refresh',
          actionLabel: 'Refresh',
        }),
        note(`Updated ${host.format.ago(loadedAt)} · ${cfg.refreshLabel} cadence`, { priority: 'detail' }),
      ];
    }

    if (summaries.length === 0) {
      return [
        empty('arrow.triangle.branch', 'All PRs hidden by filters', {
          message: `${pulls.length} open ${pulls.length === 1 ? 'PR is' : 'PRs are'} hidden by your draft or repo filters.`,
          action: 'showAll',
          actionLabel: 'Show all open',
        }),
        note(`Updated ${host.format.ago(loadedAt)} · ${cfg.refreshLabel} cadence`, { priority: 'detail' }),
      ];
    }

    const groups = buildStacks(summaries, cfg.groupByStack);
    const readyCount = summaries.filter((e) => e.isReady).length;
    const blockedCount = summaries.filter((e) => e.isBlocked).length;
    const stackCount = groups.filter((g) => g.kind === 'stack').length;

    const headerBadge = blockedCount > 0
      ? badge(`${blockedCount} blocked`, { tone: 'bad' })
      : readyCount > 0
        ? badge(`${readyCount} ready`, { tone: 'good' })
        : null;

    const blocks = [
      row([
        icon('arrow.triangle.branch', { tone: blockedCount > 0 ? 'bad' : readyCount > 0 ? 'good' : undefined }),
        text(`${summaries.length} open`, { role: 'label', tone: 'primary', weight: 'semibold', mono: true }),
        spacer(),
        ...(headerBadge ? [headerBadge] : []),
      ], { spacing: 'tight' }),
      ...groups.slice(0, 10).map((group) => section(group.title, [
        list(group.rows.slice(0, 30).map((r) => renderPRRow(host, r))),
      ], { trailing: group.trailing })),
    ];

    if (failure) {
      blocks.push(note(`Cached · ${failure}`, { tone: 'warn', icon: 'exclamationmark.triangle.fill', priority: 'detail' }));
    } else {
      const meta = [host.format.ago(loadedAt)];
      if (stackCount > 0) meta.push(`${stackCount} ${stackCount === 1 ? 'stack' : 'stacks'}`);
      blocks.push(note(meta.join(' · '), { priority: 'detail' }));
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
      section('Display', [
        toggle('Group by PR stacks', cfg.groupByStack, 'setGroupByStack'),
        toggle('Include drafts', cfg.includeDrafts, 'setIncludeDrafts'),
        toggle('Ignore bot reviews', cfg.ignoreBots, 'setIgnoreBots'),
      ]),
      section('Repositories', repoChildren, { trailing: cfg.repoMode === 'All repos' ? 'All' : String(cfg.selectedRepos.length) }),
      section('Updates', [
        segmented(Object.keys(REFRESH_OPTIONS), cfg.refreshLabel, 'setRefresh'),
        toggle('Notify on status changes', cfg.notifyChanges, 'setNotifyChanges'),
        button('Refresh now', 'refresh', { icon: 'arrow.clockwise' }),
      ]),
    ];
  },
  actions: {
    setGroupByStack(host, isOn) {
      host.storage.set('groupByStack', !!isOn);
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
    setNotifyChanges(host, isOn) {
      host.storage.set('notifyChanges', !!isOn);
    },
    showAll(host) {
      host.storage.set('includeDrafts', true);
      host.storage.set('repoMode', 'All repos');
    },
    async refresh(host) {
      loadedAt = 0;
      await load(host, true);
    },
  },
});

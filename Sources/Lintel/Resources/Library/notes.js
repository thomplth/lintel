function noteRows(host, entries, compact) {
  return list(entries.map((entry) => item(entry.text, {
    icon: entry.done ? 'checkmark.circle.fill' : 'circle',
    tone: entry.done ? 'good' : undefined,
    subtitle: host.format.ago(entry.at),
    action: 'toggle',
    payload: entry.id,
  })), { compact });
}

defineModule({
  meta: {
    id: 'notes',
    title: 'Notes',
    icon: 'checklist',
    summary: 'A to-do list one glance away; grows from an open count badge to a full task widget.',
    pinned: false,
    order: 45,
    refreshSeconds: 30,
    sizes: ['chip', 'small', 'wide', 'medium', 'tall'],
    defaultSize: 'medium',
  },
  views: {
    chip(host) {
      const open = host.storage.get('notes', []).filter((entry) => !entry.done).length;
      return open === 0 ? icon('checklist') : row([icon('checklist'), badge(open)]);
    },
    small(host) {
      const open = host.storage.get('notes', []).filter((entry) => !entry.done);
      return [
        row([icon('checklist', { tone: 'accent' }), text('Notes', { role: 'label', weight: 'semibold' }), spacer(), badge(open.length)]),
        open.length > 0
          ? noteRows(host, open.slice(0, 10), true)
          : empty('checklist', 'All clear'),
      ];
    },
    wide(host) {
      const notes = host.storage.get('notes', []);
      const open = notes.filter((entry) => !entry.done);
      return [
        split([
          column([
            stat('Open', open.length, { icon: 'checklist', caption: `${notes.length - open.length} done` }),
            field('Add a note', 'add', { icon: 'plus' }),
          ], { spacing: 'tight' }),
          open.length > 0
            ? noteRows(host, open.slice(0, 12), true)
            : empty('checklist', 'Nothing to do'),
        ], { weights: [1, 1.35] }),
      ];
    },
    medium(host) {
      const notes = host.storage.get('notes', []);
      const open = notes.filter((entry) => !entry.done), done = notes.filter((entry) => entry.done);
      return [
        field('Add a note', 'add', { icon: 'plus' }),
        notes.length === 0 ? empty('checklist', 'Nothing to do', { message: 'Type a note above and press Return.' }) : null,
        open.length > 0 ? section('Open', [noteRows(host, open.slice(0, 16), true)], { trailing: String(open.length) }) : null,
        done.length > 0 ? row([
          text(`${done.length} completed`, { role: 'caption', tone: 'secondary' }),
          spacer(),
          button('Clear done', 'clear', { icon: 'trash', style: 'plain' }),
        ]) : null,
      ].filter(Boolean);
    },
    tall(host) {
      const notes = host.storage.get('notes', []);
      const open = notes.filter((entry) => !entry.done), done = notes.filter((entry) => entry.done);
      return [
        field('Add a note', 'add', { icon: 'plus' }),
        notes.length === 0 ? empty('checklist', 'Nothing to do', { message: 'Type a note above and press Return.' }) : null,
        open.length > 0 ? section('Open', [noteRows(host, open.slice(0, 20), false)], { trailing: String(open.length) }) : null,
        done.length > 0 ? section('Done', [
          noteRows(host, done.slice(0, 8), true),
          button('Clear done', 'clear', { icon: 'trash', style: 'plain' }),
        ], { priority: 'supporting' }) : null,
      ].filter(Boolean);
    },
  },
  actions: {
    add(host, text) {
      const notes = host.storage.get('notes', []);
      notes.unshift({ id: Date.now(), text: host.format.truncate(text, 80), at: Date.now(), done: false });
      host.storage.set('notes', notes.slice(0, 60));
    },
    toggle(host, id) {
      host.storage.set('notes', host.storage.get('notes', []).map((entry) => (
        entry.id === id ? { id: entry.id, text: entry.text, at: entry.at, done: !entry.done } : entry
      )));
    },
    clear(host) {
      host.storage.set('notes', host.storage.get('notes', []).filter((entry) => !entry.done));
    },
  },
});

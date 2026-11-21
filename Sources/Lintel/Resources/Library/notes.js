function noteRows(host, entries) {
  return list(entries.slice(0, 30).map((entry) => item(entry.text, {
    icon: entry.done ? 'checkmark.circle.fill' : 'circle',
    tone: entry.done ? 'good' : undefined,
    subtitle: host.format.ago(entry.at),
    action: 'toggle',
    payload: entry.id,
  })));
}

defineModule({
  meta: {
    id: 'notes',
    title: 'Notes',
    icon: 'checklist',
    summary: 'A to-do list one glance away; grows smoothly from a compact checklist to a full task widget.',
    pinned: false,
    order: 45,
    refreshSeconds: 30,
    defaultShape: 'card',
  },
  chip(host) {
    const open = host.storage.get('notes', []).filter((entry) => !entry.done).length;
    return open === 0 ? icon('checklist') : row([icon('checklist'), badge(open)]);
  },
  widget(host) {
    const notes = host.storage.get('notes', []);
    const open = notes.filter((entry) => !entry.done);
    const done = notes.filter((entry) => entry.done);
    return [
      field('Add a note', 'add', { icon: 'plus' }),
      notes.length === 0 ? empty('checklist', 'Nothing to do', { message: 'Type a note above and press Return.' }) : null,
      open.length > 0 ? section('Open', [noteRows(host, open)], { trailing: String(open.length) }) : null,
      done.length > 0 ? section('Done', [
        noteRows(host, done),
        button('Clear done', 'clear', { icon: 'trash', style: 'plain' }),
      ], { priority: 'supporting' }) : null,
    ].filter(Boolean);
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

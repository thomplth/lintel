defineModule({
  meta: {
    id: 'notes',
    title: 'Notes',
    icon: 'checklist',
    summary: 'A short to-do list one click away; the bar shows how many are open.',
    pinned: false,
    order: 45,
    refreshSeconds: 30,
    panelWidth: 'small',
  },
  render(host) {
    const open = host.storage.get('notes', []).filter((entry) => !entry.done).length;
    return open === 0 ? icon('checklist') : row([icon('checklist'), badge(open)]);
  },
  panel(host) {
    const notes = host.storage.get('notes', []);
    const open = notes.filter((entry) => !entry.done), done = notes.filter((entry) => entry.done);
    const rows = (entries) => list(entries.map((entry) => item(entry.text, {
      icon: entry.done ? 'checkmark.circle.fill' : 'circle', tone: entry.done ? 'good' : undefined,
      subtitle: host.format.ago(entry.at), action: 'toggle', payload: entry.id,
    })));
    return [
      field('Add a note', 'add', { icon: 'plus' }),
      notes.length === 0 ? empty('checklist', 'Nothing to do', { message: 'Type a note above and press Return.' }) : null,
      open.length > 0 ? section('Open', [rows(open.slice(0, 12))], { trailing: String(open.length) }) : null,
      done.length > 0 ? section('Done', [rows(done.slice(0, 6)), button('Clear done', 'clear', { icon: 'trash', style: 'plain' })]) : null,
    ];
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

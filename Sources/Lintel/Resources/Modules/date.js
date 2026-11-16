defineModule({
  meta: {
    id: 'date',
    title: 'Date',
    icon: 'calendar',
    summary: 'Today\'s weekday and date.',
    pinned: false,
    order: 80,
    refreshSeconds: 60,
  },
  render(host) {
    return text(host.format.date());
  },
});

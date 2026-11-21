const page = `
<style>
  html, body { height: 100%; margin: 0; padding: 0; overflow: hidden; }
  .wrap { display: flex; flex-direction: column; height: 100%; gap: calc(var(--lt-unit) * 1.5); }
  .tools { display: flex; gap: calc(var(--lt-unit) * 1.5); align-items: center; flex-shrink: 0; }
  .tools.hidden { display: none; }
  .swatch { width: 16px; height: 16px; border-radius: 50%; border: 2px solid transparent; cursor: pointer; }
  .swatch.on { border-color: var(--lt-text); }
  canvas { width: 100%; flex: 1; min-height: 0; border-radius: var(--lt-radius); background: var(--lt-fill); touch-action: none; cursor: crosshair; display: block; }
  .grow { flex: 1; }
</style>
<div class="wrap">
  <div class="tools" id="tools">
    <span class="swatch on" data-color="text"></span>
    <span class="swatch" data-color="accent" style="background: var(--lt-accent)"></span>
    <span class="swatch" data-color="good" style="background: var(--lt-good)"></span>
    <span class="swatch" data-color="warn" style="background: var(--lt-warn)"></span>
    <span class="swatch" data-color="bad" style="background: var(--lt-bad)"></span>
    <span class="grow"></span>
    <button class="lt-button" id="undo">Undo</button>
    <button class="lt-button" id="clear">Clear</button>
  </div>
  <canvas id="pad"></canvas>
</div>
<script>
  const pad = document.getElementById('pad'), ink = pad.getContext('2d'), tools = document.getElementById('tools');
  let strokes = [], current = null, color = 'text', readOnly = false;
  const resolve = (name) => getComputedStyle(document.documentElement).getPropertyValue('--lt-' + name).trim();
  document.querySelector('.swatch').style.background = 'var(--lt-text)';
  function size() {
    const scale = window.devicePixelRatio || 1;
    pad.width = Math.max(1, pad.clientWidth * scale); pad.height = Math.max(1, pad.clientHeight * scale);
    ink.setTransform(scale, 0, 0, scale, 0, 0);
    draw();
  }
  function draw() {
    ink.clearRect(0, 0, pad.clientWidth, pad.clientHeight);
    ink.lineWidth = readOnly ? 1.8 : 2.5; ink.lineCap = 'round'; ink.lineJoin = 'round';
    for (const stroke of strokes.concat(current ? [current] : [])) {
      ink.strokeStyle = resolve(stroke.color);
      ink.beginPath();
      stroke.points.forEach((point, index) => index === 0 ? ink.moveTo(point[0], point[1]) : ink.lineTo(point[0], point[1]));
      if (stroke.points.length === 1) ink.lineTo(stroke.points[0][0] + 0.1, stroke.points[0][1]);
      ink.stroke();
    }
  }
  const at = (event) => { const box = pad.getBoundingClientRect(); return [Math.round(event.clientX - box.left), Math.round(event.clientY - box.top)]; };
  pad.addEventListener('pointerdown', (event) => { if (readOnly) return; pad.setPointerCapture(event.pointerId); current = { color, points: [at(event)] }; draw(); });
  pad.addEventListener('pointermove', (event) => { if (current) { current.points.push(at(event)); draw(); } });
  pad.addEventListener('pointerup', () => { if (!current) return; strokes.push(current); current = null; lintel.send('save', strokes); });
  document.getElementById('clear').onclick = () => { strokes = []; draw(); lintel.send('save', strokes); };
  document.getElementById('undo').onclick = () => { strokes.pop(); draw(); lintel.send('save', strokes); };
  document.querySelectorAll('.swatch').forEach((swatch) => swatch.onclick = () => {
    document.querySelectorAll('.swatch').forEach((other) => other.classList.remove('on'));
    swatch.classList.add('on'); color = swatch.dataset.color;
  });
  let isRestored = false;
  lintel.onState((state) => {
    readOnly = !!(state && state.readOnly);
    tools.classList.toggle('hidden', readOnly);
    pad.style.cursor = readOnly ? 'default' : 'crosshair';
    if (!isRestored) { isRestored = true; strokes = (state && state.strokes) || []; }
    size();
  });
  new ResizeObserver(size).observe(pad);
  window.addEventListener('resize', size);
  size();
</script>`;

defineModule({
  meta: {
    id: 'sketchpad',
    title: 'Sketchpad',
    icon: 'scribble.variable',
    summary: 'A resizable drawing pad that fills its widget and keeps your sketch between openings.',
    pinned: false,
    order: 48,
    refreshSeconds: 3600,
    panelRefreshSeconds: 3600,
    sizes: ['chip', 'small', 'medium', 'large'],
    defaultSize: 'medium',
  },
  views: {
    chip(host) {
      const count = host.storage.get('strokes', []).length;
      return count === 0 ? icon('scribble.variable') : row([icon('scribble.variable'), text(count, { mono: true, tone: 'secondary' })]);
    },
    small(host) {
      return [app(page, { height: 'fill', state: { strokes: host.storage.get('strokes', []), readOnly: true } })];
    },
    medium(host) {
      return [app(page, { height: 'fill', state: { strokes: host.storage.get('strokes', []), readOnly: false } })];
    },
    large(host) {
      return [app(page, { height: 'fill', state: { strokes: host.storage.get('strokes', []), readOnly: false } })];
    },
  },
  actions: {
    save(host, strokes) {
      host.storage.set('strokes', Array.isArray(strokes) ? strokes.slice(-400) : []);
    },
  },
});

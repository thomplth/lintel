public enum ModulePrelude {
    /// Evaluated in every module's context before the module file. `__call` and `__post` are installed natively.
    public static let source = #"""
    var __module = null, __data = {}, __storage = {}, __history = {};
    function defineModule(module) { __module = module; }

    function __node(type, props, children) {
      var node = { type: type };
      for (var key in props) { if (props[key] !== undefined && props[key] !== null) node[key] = props[key]; }
      if (children !== undefined) node.children = children;
      return node;
    }
    function __options(value) { return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
    function __string(value) { return value === undefined || value === null ? '' : String(value); }

    function text(value, options) {
      var o = __options(options);
      return __node('text', { value: __string(value), role: o.role, tone: o.tone || o.color, weight: o.weight,
        mono: o.mono !== undefined ? o.mono : o.monospacedDigits, lines: o.lines });
    }
    function icon(name, options) { var o = __options(options); return __node('icon', { name: __string(name), tone: o.tone || o.color, size: o.size }); }
    function dot(tone) { return __node('dot', { tone: typeof tone === 'object' ? __options(tone).tone : tone }); }
    function badge(value, options) { var o = __options(options); return __node('badge', { value: __string(value), tone: o.tone || o.color }); }
    function gauge(value, options) { var o = __options(options); return __node('gauge', { value: Number(value), tone: o.tone || o.color }); }
    function ring(value, options) { var o = __options(options); return __node('ring', { value: Number(value), tone: o.tone || o.color }); }
    function sparkline(values, options) { var o = __options(options); return __node('sparkline', { values: values, tone: o.tone || o.color, kind: o.kind }); }
    function row(children, options) { var o = __options(options); return __node('row', { spacing: o.spacing, align: o.align }, children); }
    function spacer() { return __node('spacer', {}); }
    function column(children, options) { var o = __options(options); return __node('column', { spacing: o.spacing, align: o.align }, children); }
    function section(title, children, options) {
      if (Array.isArray(title)) { options = children; children = title; title = undefined; }
      var o = __options(options);
      return __node('section', { title: title, trailing: o.trailing }, children);
    }
    function grid(columns, children, options) { var o = __options(options); return __node('grid', { columns: Number(columns), spacing: o.spacing }, children); }
    function stat(label, value, options) {
      var o = __options(options);
      return __node('stat', { label: __string(label), value: __string(value), unit: o.unit, icon: o.icon, tone: o.tone || o.color, caption: o.caption, trend: o.trend });
    }
    function meter(label, fraction, options) {
      var o = __options(options);
      return __node('meter', { label: __string(label), fraction: Number(fraction), value: o.value, tone: o.tone || o.color, icon: o.icon });
    }
    function chart(data, options) {
      var o = __options(options);
      var isSeries = Array.isArray(data) && data.length > 0 && typeof data[0] === 'object' && data[0] !== null;
      return __node('chart', { values: isSeries ? undefined : data, series: isSeries ? data : undefined, kind: o.kind,
        tone: o.tone || o.color, height: o.height, min: o.min, max: o.max, labels: o.labels });
    }
    function list(items) { return __node('list', {}, items); }
    function item(title, options) {
      var o = __options(options);
      return __node('item', { title: __string(title), subtitle: o.subtitle, icon: o.icon, value: o.value, badge: o.badge,
        tone: o.tone || o.color, action: o.action, payload: o.payload, url: o.url });
    }
    function keyValue(label, value, options) { var o = __options(options); return __node('keyValue', { label: __string(label), value: __string(value), tone: o.tone || o.color, mono: o.mono }); }
    function button(label, action, options) {
      if (action && typeof action === 'object') { options = action; action = undefined; }
      var o = __options(options);
      return __node('button', { label: __string(label), action: action || o.action, icon: o.icon, style: o.style, payload: o.payload, url: o.url });
    }
    function toggle(label, on, action, options) { var o = __options(options); return __node('toggle', { label: __string(label), on: !!on, action: action, icon: o.icon }); }
    function segmented(options, selected, action) { return __node('segmented', { options: options, selected: __string(selected), action: action }); }
    function slider(value, action, options) {
      var o = __options(options);
      return __node('slider', { value: Number(value), action: action, min: o.min, max: o.max, step: o.step, label: o.label, icon: o.icon });
    }
    function field(placeholder, action, options) {
      var o = __options(options);
      return __node('field', { placeholder: __string(placeholder), action: action, value: o.value, icon: o.icon, submitLabel: o.submitLabel });
    }
    function divider() { return __node('divider', {}); }
    function note(value, options) { var o = __options(options); return __node('note', { value: __string(value), tone: o.tone || o.color, icon: o.icon }); }
    function progress(value, options) {
      var o = __options(options);
      return __node('progress', { value: value === null || value === undefined ? undefined : Number(value), label: o.label, tone: o.tone || o.color });
    }
    function image(url, options) { var o = __options(options); return __node('image', { url: __string(url), height: o.height }); }
    function empty(iconName, title, options) {
      var o = __options(options);
      return __node('empty', { icon: __string(iconName), title: __string(title), message: o.message, action: o.action, actionLabel: o.actionLabel });
    }
    function web(url, options) {
      var o = __options(options);
      return __node('web', { url: __string(url), height: o.height, selector: o.selector, interactive: o.interactive, zoom: o.zoom, reloadSeconds: o.reloadSeconds });
    }
    function app(html, options) { var o = __options(options); return __node('app', { html: __string(html), height: o.height, state: o.state }); }

    function __async(name, args) {
      return new Promise(function (resolve, reject) {
        __call(name, JSON.stringify(args), function (json) {
          try { resolve(json === undefined || json === null ? null : JSON.parse(json)); } catch (error) { reject(error); }
        }, function (message) { reject(new Error(message)); });
      });
    }
    function __pad(value) { return (value < 10 ? '0' : '') + value; }
    function __scaled(value, units, base) {
      var index = 0; value = Math.max(Number(value) || 0, 0);
      while (value >= base && index < units.length - 1) { value /= base; index += 1; }
      return (index === 0 || value >= 100 ? String(Math.round(value)) : value.toFixed(1)) + ' ' + units[index];
    }

    var host = {
      system: function () { return __data.system || { cpu: 0, cores: [], loadAverage: [0, 0, 0], memoryUsed: 0, memoryTotal: 0, memoryPressure: 0, swapUsed: 0, gpu: null, uptime: 0, thermal: 'nominal', battery: null }; },
      network: function () { return __data.network || { down: 0, up: 0, interface: null, ip: null, wifi: null }; },
      disk: function () { return __data.disk || { volumes: [], readRate: 0, writeRate: 0 }; },
      processes: function () { return __data.processes || []; },
      audio: function () { return __data.audio || { volume: 0, muted: false, output: null }; },
      bluetooth: function () { return __data.bluetooth || { on: false, devices: [] }; },
      appearance: function () { return __data.appearance || { dark: true }; },
      setVolume: function (fraction) { return __async('audio.setVolume', [Number(fraction)]); },
      setMuted: function (muted) { return __async('audio.setMuted', [!!muted]); },
      storage: {
        get: function (key, fallback) { return Object.prototype.hasOwnProperty.call(__storage, key) ? __storage[key] : fallback; },
        set: function (key, value) { __storage[key] = value; __post('storage.set', JSON.stringify([String(key), value === undefined ? null : value])); },
        remove: function (key) { delete __storage[key]; __post('storage.remove', JSON.stringify([String(key)])); }
      },
      history: function (key, value, max) {
        var series = __history[key] || (__history[key] = []);
        if (typeof value === 'number' && isFinite(value)) series.push(value);
        while (series.length > (max || 60)) series.shift();
        return series.slice();
      },
      fetchJSON: function (url, options) {
        return __async('fetch', [String(url), __options(options)]).then(function (body) {
          try { return JSON.parse(body); } catch (error) { throw new Error('the response from ' + url + ' is not JSON'); }
        });
      },
      fetchText: function (url, options) { return __async('fetch', [String(url), __options(options)]); },
      browser: {
        text: function (url, selector) { return __async('browser.text', [String(url), String(selector)]); },
        all: function (url, selector) { return __async('browser.all', [String(url), String(selector)]); }
      },
      secret: function (name) { return __async('secret', [String(name)]); },
      exec: function (tool, args, options) { return __async('exec', [String(tool), (args || []).map(String), __options(options)]); },
      notify: function (title, body) { __post('notify', JSON.stringify([__string(title), __string(body)])); },
      open: function (url) { __post('open', JSON.stringify([String(url)])); },
      copy: function (value) { __post('copy', JSON.stringify([__string(value)])); },
      refresh: function () { __post('refresh', '[]'); },
      attention: function (isRaised) { __post('attention', JSON.stringify([!!isRaised])); },
      log: function () { __post('log', JSON.stringify(Array.prototype.map.call(arguments, __string))); },
      format: {
        bytes: function (value) { return __scaled(value, ['B', 'kB', 'MB', 'GB', 'TB'], 1000); },
        rate: function (value) { return __scaled(value, ['B/s', 'kB/s', 'MB/s', 'GB/s'], 1000); },
        percent: function (fraction, digits) { return (Number(fraction) * 100).toFixed(digits || 0) + '%'; },
        number: function (value) { return Math.round(Number(value) || 0).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ','); },
        compact: function (value) {
          value = Number(value) || 0;
          var units = ['', 'k', 'M', 'B'], index = 0;
          while (Math.abs(value) >= 1000 && index < units.length - 1) { value /= 1000; index += 1; }
          return (index === 0 ? Math.round(value).toString() : value.toFixed(Math.abs(value) >= 100 ? 0 : 1).replace(/\.0$/, '')) + units[index];
        },
        duration: function (seconds) {
          seconds = Math.max(Math.round(Number(seconds) || 0), 0);
          var days = Math.floor(seconds / 86400), hours = Math.floor(seconds % 86400 / 3600), minutes = Math.floor(seconds % 3600 / 60);
          if (days > 0) return days + 'd ' + hours + 'h';
          if (hours > 0) return hours + 'h ' + __pad(minutes) + 'm';
          if (minutes > 0) return minutes + 'm ' + __pad(seconds % 60) + 's';
          return seconds + 's';
        },
        timer: function (seconds) {
          seconds = Math.max(Math.round(Number(seconds) || 0), 0);
          var hours = Math.floor(seconds / 3600), minutes = Math.floor(seconds % 3600 / 60);
          return (hours > 0 ? hours + ':' + __pad(minutes) : String(minutes)) + ':' + __pad(seconds % 60);
        },
        ago: function (when) {
          var seconds = Math.max((Date.now() - new Date(when).getTime()) / 1000, 0);
          if (seconds < 45) return 'just now';
          if (seconds < 3600) return Math.round(seconds / 60) + ' min ago';
          if (seconds < 86400) return Math.round(seconds / 3600) + ' h ago';
          return Math.round(seconds / 86400) + ' d ago';
        },
        time: function (when, options) {
          var date = when ? new Date(when) : new Date(), o = __options(options);
          return __pad(date.getHours()) + ':' + __pad(date.getMinutes()) + (o.seconds ? ':' + __pad(date.getSeconds()) : '');
        },
        date: function (when, style) {
          var date = when ? new Date(when) : new Date();
          var days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
          var months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
          var short = days[date.getDay()] + ' ' + date.getDate() + ' ' + months[date.getMonth()];
          return style === 'long' ? short + ' ' + date.getFullYear() : short;
        },
        truncate: function (value, max) {
          value = __string(value); max = max || 24;
          return value.length > max ? value.slice(0, max - 1).replace(/\s+$/, '') + '…' : value;
        }
      }
    };

    function __message(error) {
      var message = String((error && error.message) || error);
      return error && error.line ? message + ' (line ' + error.line + ')' : message;
    }
    function __describe() {
      if (!__module || typeof __module !== 'object') return null;
      return JSON.stringify({
        meta: __module.meta || null,
        hasRender: typeof (__module.render || __module.chip) === 'function',
        hasPanel: typeof __module.panel === 'function',
        actions: Object.keys(__module.actions || {})
      });
    }
    function __render(surface, done) {
      var render = surface === 'panel' ? __module.panel : (__module.render || __module.chip);
      var pending;
      try { pending = Promise.resolve(render.call(__module, host)); } catch (error) { pending = Promise.reject(error); }
      pending.then(
        function (tree) { done(JSON.stringify(tree === undefined ? null : tree), null); },
        function (error) { done(null, __message(error)); });
    }
    function __act(name, payloadJSON, done) {
      var action = (__module.actions || {})[name];
      if (typeof action !== 'function') { done(null, 'the module has no action named ' + name); return; }
      var pending;
      try { pending = Promise.resolve(action.call(__module.actions, host, JSON.parse(payloadJSON))); } catch (error) { pending = Promise.reject(error); }
      pending.then(
        function (result) { done(JSON.stringify(result === undefined ? null : result), null); },
        function (error) { done(null, __message(error)); });
    }
    function __setData(json) { __data = JSON.parse(json); }
    function __setStorage(json) { __storage = JSON.parse(json); }
    """#
}

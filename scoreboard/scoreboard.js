// Arc PH all-day scoreboard. One script for both pages:
//   index.html   the TV (read only)
//   keeper.html  the scorekeeper's phone (PIN protected)
// The browser only reads the public scoreboard_state row. Every change goes
// through an sb_* database function that checks the keeper PIN.
(function () {

  // ================================================================ points
  // Edit the point values here. Nothing else needs to change.
  //   buttons: one tap adds `points` to that group, shown on the TV as `label`.
  //   entry 'points': the keeper types the points for a group.
  //   entry 'count':  the keeper types a count, which adds count x perItem.
  //   entry 'signed': plus or minus points with a short reason.
  // The keys go into the database with each award, so keep them short,
  // lowercase, and the same all day.
  var GAMES = [
    { key: 'prompt', name: 'Prompt Battle', buttons: [
      { text: '1st place', points: 300, label: 'Prompt Battle 1st' },
      { text: '2nd place', points: 150, label: 'Prompt Battle 2nd' }
    ] },
    { key: 'bug1', name: 'Spot the Bug R1', buttons: [
      { text: 'First correct', points: 300, label: 'Spot the Bug R1 first' },
      { text: 'Correct', points: 100, label: 'Spot the Bug R1' }
    ] },
    { key: 'bug2', name: 'Spot the Bug R2', buttons: [
      { text: 'Arc Studio review shown', points: 100, label: 'Spot the Bug R2 review' }
    ] },
    // The quiz rule is not decided yet, so the quiz points are typed in by hand.
    { key: 'quiz', name: 'Quiz', entry: 'points', label: 'Group quiz' },
    // Points per note on the Deploy Wall.
    { key: 'deploy', name: 'Deploy', entry: 'count', perItem: 50, unit: 'note', label: 'Deploy Wall' },
    { key: 'other', name: 'Other', entry: 'signed', label: 'Other' }
  ];

  var GROUPS = ['Bobbilee', 'Sam', 'Tim', 'Rachel', 'Jeremy', 'Blessing'];

  // Keep in step with _sb_segments() in scoreboard.sql.
  var SEGMENTS = ['Setup', 'Check-in', 'Welcome', 'Prompt Battle', 'Spot the Bug',
    'Break and Builder Bingo', 'Group quiz', 'Deploy', 'Agent demo',
    'Builder pitches', 'Scores and prizes', 'Networking'];

  var TIMER_PRESETS = [2, 5, 10, 15, 40]; // minutes
  var CODE = 'ARCPH';

  // ================================================================ shared
  var cfg = window.QUIZ_CONFIG || {};
  var configured = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY &&
    cfg.SUPABASE_URL.indexOf('YOUR-') < 0 && cfg.SUPABASE_ANON_KEY.indexOf('YOUR-') < 0);
  var client = null;
  if (configured && window.supabase) {
    client = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
    });
  }

  var $ = function (id) { return document.getElementById(id); };

  // Storage can be missing or throw (private mode, blocked site data).
  function wrap(kind) {
    return {
      get: function (k) { try { return window[kind].getItem(k); } catch (e) { return null; } },
      set: function (k, v) { try { window[kind].setItem(k, v); } catch (e) {} },
      del: function (k) { try { window[kind].removeItem(k); } catch (e) {} },
      getJSON: function (k) { try { return JSON.parse(window[kind].getItem(k)); } catch (e) { return null; } },
      setJSON: function (k, v) { try { window[kind].setItem(k, JSON.stringify(v)); } catch (e) {} }
    };
  }
  var local = wrap('localStorage');
  var session = wrap('sessionStorage');

  function withTimeout(promise, ms) {
    var timer;
    var timeout = new Promise(function (resolve) {
      timer = setTimeout(function () { resolve({ error: { message: 'timeout' } }); }, ms);
    });
    return Promise.race([promise, timeout]).then(function (r) { clearTimeout(timer); return r; });
  }

  // RPC with a timeout. Resolves { data } or { error, message, network }.
  function rpc(fn, args, timeoutMs) {
    if (!client) return Promise.resolve({ error: 'not_configured', network: true });
    var call = client.rpc(fn, args).then(function (res) { return res; },
      function (err) { return { error: { message: String(err && err.message || err) } }; });
    return withTimeout(call, timeoutMs || 8000).then(function (res) {
      if (res.error) {
        var msg = res.error.message || String(res.error);
        var network = !res.error.code || /fetch|network|Failed|Load failed|timeout/i.test(msg);
        return { error: msg, message: msg, network: network };
      }
      if (res.data && res.data.error) return { error: res.data.error, message: res.data.message, data: res.data };
      return { data: res.data };
    });
  }

  // Postgres timestamps have microseconds; trim to milliseconds for every browser.
  function ts(s) {
    if (!s) return null;
    if (typeof s === 'number') return s;
    var t = String(s).replace(' ', 'T').replace(/(\.\d{3})\d+/, '$1');
    if (/[+-]\d\d$/.test(t)) t += ':00';
    var ms = Date.parse(t);
    return isNaN(ms) ? null : ms;
  }

  // Server clock. Keep the sample with the shortest round trip.
  var offset = 0, bestRtt = Infinity;
  function syncClock(serverNow, sentAt, gotAt) {
    var server = ts(serverNow);
    if (!server) return;
    var rtt = gotAt - sentAt;
    if (rtt <= bestRtt || rtt < 400) {
      bestRtt = Math.min(rtt, bestRtt);
      offset = server - (sentAt + gotAt) / 2;
    }
  }
  function now() { return Date.now() + offset; }
  function checkClock() {
    var sent = Date.now();
    return rpc('sb_server_time', {}).then(function (r) {
      if (!r.error) syncClock(r.data, sent, Date.now());
      return r;
    });
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function num(n) { return Math.round(Number(n) || 0).toLocaleString('en-US'); }
  function signed(n) { n = Math.round(Number(n) || 0); return (n < 0 ? '−' : '+') + num(Math.abs(n)); }
  function awardText(a) { return a ? signed(a.points) + ' ' + a.group + ' · ' + a.label : ''; }

  function totalsOf(state) {
    var t = (state && state.totals) || {};
    if (typeof t === 'string') { try { t = JSON.parse(t); } catch (e) { t = {}; } }
    var out = {};
    GROUPS.forEach(function (g) { out[g] = Number(t[g]) || 0; });
    return out;
  }
  function lastAward(state) {
    var a = state && state.last_award;
    if (typeof a === 'string') { try { a = JSON.parse(a); } catch (e) { a = null; } }
    return a || null;
  }

  // Highest total first. Ties keep the fixed group order. Equal totals share a rank.
  function ranking(totals) {
    var rows = GROUPS.map(function (g, i) { return { name: g, order: i, total: totals[g] }; });
    rows.sort(function (a, b) { return b.total - a.total || a.order - b.order; });
    rows.forEach(function (r) {
      r.rank = 1 + rows.filter(function (o) { return o.total > r.total; }).length;
    });
    return rows;
  }

  // ---------------------------------------------------------------- timer
  // Seconds left (can go negative while running).
  function timerLeft(s) {
    if (!s) return 0;
    if (s.timer_running && s.timer_ends_at) return (ts(s.timer_ends_at) - now()) / 1000;
    var r = s.timer_remaining_s;
    return r == null ? (Number(s.timer_duration_s) || 0) : Number(r);
  }
  // idle (nothing loaded), ready, running, paused, done
  function timerPhase(s, left) {
    if (!s) return 'idle';
    if (s.timer_running) return left > 0 ? 'running' : 'done';
    var dur = Number(s.timer_duration_s) || 0;
    if (dur <= 0) return 'idle';
    if (left <= 0) return 'done';
    return left < dur - 0.05 ? 'paused' : 'ready';
  }
  function mmss(left) {
    var t = Math.max(0, Math.ceil(left - 0.001));
    var m = Math.floor(t / 60), sec = t % 60;
    return (m < 10 ? '0' : '') + m + ':' + (sec < 10 ? '0' : '') + sec;
  }
  var PHASE_TEXT = { idle: 'No timer', ready: 'Ready', running: 'Running', paused: 'Paused', done: 'Time is up' };

  // ---------------------------------------------------------------- live row
  // Both pages keep the latest state row, from realtime, polls and RPC replies.
  var L = {
    state: null,
    chanStatus: null,
    everSubscribed: false,
    channelAt: Date.now(),
    netOk: true,
    onState: null,   // function (state, prev)
    onChip: null
  };

  // Accepts a row if it is newer than the one shown. Returns true if applied.
  function applyState(row) {
    if (!row || !row.code) return false;
    var cur = L.state;
    if (cur && cur.id === row.id && Number(row.rev) < Number(cur.rev)) return false;
    if (cur && cur.id === row.id && Number(row.rev) === Number(cur.rev)) return false;
    L.state = row;
    if (L.onState) L.onState(row, cur);
    return true;
  }

  function setNet(ok) {
    if (L.netOk === ok) return;
    L.netOk = ok;
    renderChip();
  }

  function fetchState() {
    if (!client) { setNet(false); return Promise.resolve(); }
    var q = client.from('scoreboard_state').select('*').eq('code', CODE).maybeSingle()
      .then(function (r) { return r; }, function (err) { return { error: { message: String(err) } }; });
    return withTimeout(q, 8000).then(function (r) {
      if (r.error) { setNet(false); return; }
      setNet(true);
      if (r.data) applyState(r.data);
    });
  }

  function subscribe() {
    if (!client) return;
    L.channelAt = Date.now();
    client.channel('scoreboard-' + CODE)
      .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'scoreboard_state', filter: 'code=eq.' + CODE },
        function (payload) { if (payload && payload.new) applyState(payload.new); })
      .subscribe(function (status) {
        var was = L.chanStatus;
        L.chanStatus = status;
        // Catch up on anything missed while the socket was down.
        if (status === 'SUBSCRIBED' && was !== 'SUBSCRIBED') { fetchState(); checkClock(); }
        L.everSubscribed = L.everSubscribed || status === 'SUBSCRIBED';
        renderChip();
      });
  }

  function chipState() {
    if (!client) return 'offline';
    if (navigator.onLine === false || !L.netOk) return 'offline';
    if (L.chanStatus === 'SUBSCRIBED') return 'live';
    if (!L.everSubscribed && Date.now() - L.channelAt < 6000) return 'connecting';
    return 'offline';
  }
  function renderChip() {
    var st = chipState();
    var el = $('chip');
    if (el) {
      el.className = 'chip ' + st;
      el.lastElementChild.textContent = st === 'live' ? 'Live' : st === 'connecting' ? 'Connecting' : 'Offline';
    }
    if (L.onChip) L.onChip(st);
  }

  // Safety net: a slow poll while realtime is up, a fast one while it is down.
  function pollLoop(fn) {
    (function loop() {
      var live = chipState() === 'live';
      Promise.resolve(fn()).then(function () { setTimeout(loop, live ? 15000 : 3000); },
        function () { setTimeout(loop, 3000); });
    })();
  }

  function startLive(poll) {
    subscribe();
    pollLoop(poll || fetchState);
    setInterval(renderChip, 2000);
    window.addEventListener('online', function () { renderChip(); fetchState(); checkClock(); });
    window.addEventListener('offline', renderChip);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') { fetchState(); checkClock(); }
    });
  }

  // ================================================================ TV
  function tv() {
    var KEY = 'sb_tv_state_' + CODE;
    var stage = $('stage'), list = $('rows');
    var els = {}, shown = {}, anim = {};
    var scale = 1;
    var lastOrder = '';
    var first = true;

    // The design is 1920 x 1080. Scale it to fit any 16:9-ish screen.
    function fit() {
      scale = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
      stage.style.transform = 'translate(-50%, -50%) scale(' + scale + ')';
    }
    window.addEventListener('resize', fit);
    fit();

    GROUPS.forEach(function (g) {
      var li = document.createElement('li');
      li.className = 'row';
      li.innerHTML = '<span class="rank"></span><span class="name">' + esc(g) + '</span>' +
        '<span class="bar"><i></i></span><span class="total">0</span>';
      list.appendChild(li);
      els[g] = li;
      shown[g] = 0;
    });

    // Count the number on screen from what it shows now to the new total.
    function countTo(g, target) {
      var from = shown[g];
      if (from === target) return;
      if (anim[g]) { cancelAnimationFrame(anim[g].frame); clearTimeout(anim[g].snap); }
      // No animation frames run while the page is hidden, so jump straight there.
      var t0 = performance.now(), dur = first || document.hidden ? 0 : 900;
      var totalEl = els[g].querySelector('.total');
      var a = anim[g] = {};
      function show(n) { shown[g] = n; totalEl.textContent = num(n); }
      (function step(t) {
        var k = dur ? Math.min(1, (t - t0) / dur) : 1;
        var e = 1 - Math.pow(1 - k, 3);
        show(k >= 1 ? target : Math.round(from + (target - from) * e));
        if (k < 1) a.frame = requestAnimationFrame(step);
      })(t0);
      // If frames stall anyway, never leave a wrong total on screen.
      if (dur) a.snap = setTimeout(function () { cancelAnimationFrame(a.frame); show(target); }, dur + 300);
    }

    // FLIP: note where each row is, reorder, then slide from the old place.
    function reorder(rows) {
      var order = rows.map(function (r) { return r.name; }).join('|');
      if (order === lastOrder) return;
      lastOrder = order;
      var before = {};
      GROUPS.forEach(function (g) { before[g] = els[g].getBoundingClientRect().top; });
      rows.forEach(function (r) { list.appendChild(els[r.name]); });
      if (first) return;
      GROUPS.forEach(function (g) {
        var dy = (before[g] - els[g].getBoundingClientRect().top) / scale;
        if (!dy) return;
        els[g].style.transition = 'none';
        els[g].style.transform = 'translateY(' + dy + 'px)';
      });
      void list.offsetHeight;
      GROUPS.forEach(function (g) {
        els[g].style.transition = '';
        els[g].style.transform = '';
      });
    }

    function pulse(g) {
      var el = els[g];
      el.classList.remove('pulse');
      void el.offsetWidth;
      el.classList.add('pulse');
    }

    function renderBoard(state, prev) {
      var totals = totalsOf(state), before = prev ? totalsOf(prev) : null;
      var rows = ranking(totals);
      var top = Math.max(rows[0].total, 0);
      reorder(rows);
      rows.forEach(function (r) {
        var el = els[r.name];
        el.querySelector('.rank').textContent = r.rank;
        el.classList.toggle('lead', r.rank === 1 && r.total > 0);
        el.querySelector('.bar i').style.width = (top > 0 ? Math.max(0, r.total) / top * 100 : 0) + '%';
        countTo(r.name, r.total);
        if (!first && before && r.total > before[r.name]) pulse(r.name);
      });
      $('segment').textContent = state.segment || 'Setup';
      var a = lastAward(state);
      $('latest').textContent = a ? awardText(a) : 'No points yet';
      // Animate from the first real row on, not from the empty placeholder.
      if (state.code) first = false;
    }

    L.onState = function (state, prev) {
      local.setJSON(KEY, state);
      renderBoard(state, prev);
      tick();
    };

    // ---------------------------------------------------------------- timer
    var lastLeft = null, lastKey = null, beeped = {};
    function tick() {
      var s = L.state;
      var left = timerLeft(s), phase = timerPhase(s, left);
      var dur = s ? Number(s.timer_duration_s) || 0 : 0;
      var digits = $('timerDigits');
      digits.textContent = phase === 'done' ? 'TIME' : mmss(left);
      digits.classList.toggle('long', Math.ceil(left) >= 6000);
      digits.classList.toggle('warn', phase === 'running' && left <= 10);
      digits.classList.toggle('done', phase === 'done');
      digits.classList.toggle('dim', phase === 'idle');
      $('timerCard').dataset.phase = phase;
      $('timerLabel').textContent = (s && s.timer_label) || (s && s.segment) || 'Timer';
      $('timerState').textContent = PHASE_TEXT[phase];
      $('timerBar').style.width = (dur > 0 ? Math.max(0, Math.min(1, left / dur)) * 100 : 0) + '%';

      // One beep when a running timer crosses zero while this page watches.
      var key = s && s.timer_running ? s.timer_ends_at : null;
      if (key && key === lastKey && lastLeft > 0 && left <= 0 && !beeped[key]) {
        beeped[key] = true;
        beep();
      }
      lastKey = key;
      lastLeft = left;
    }

    // ---------------------------------------------------------------- sound
    // Browsers only allow sound after a click or key press on the page.
    var ctx = null;
    function unlockAudio() {
      try {
        if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
        if (ctx.state === 'suspended') ctx.resume();
      } catch (e) {}
      setTimeout(function () { $('soundHint').hidden = !!(ctx && ctx.state === 'running'); }, 200);
    }
    function beep() {
      if (!ctx || ctx.state !== 'running') return;
      var t = ctx.currentTime;
      var osc = ctx.createOscillator(), gain = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.value = 880;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.5, t + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.6);
      osc.connect(gain).connect(ctx.destination);
      osc.start(t);
      osc.stop(t + 0.65);
    }

    // ---------------------------------------------------------------- screen
    function fullscreen() {
      try {
        if (document.fullscreenElement) document.exitFullscreen();
        else document.documentElement.requestFullscreen();
      } catch (e) {}
    }
    document.addEventListener('keydown', function (e) {
      unlockAudio();
      if ((e.key === 'f' || e.key === 'F') && !e.ctrlKey && !e.metaKey && !e.altKey) fullscreen();
    });
    document.addEventListener('pointerdown', unlockAudio);
    document.addEventListener('dblclick', fullscreen);

    var idleTimer;
    function awake() {
      document.body.classList.remove('idle');
      clearTimeout(idleTimer);
      idleTimer = setTimeout(function () { document.body.classList.add('idle'); }, 3000);
    }
    document.addEventListener('mousemove', awake);
    awake();

    var lock = null;
    function wakeLock() {
      if (!('wakeLock' in navigator) || lock) return;
      navigator.wakeLock.request('screen').then(function (l) {
        lock = l;
        l.addEventListener('release', function () { lock = null; });
      }, function () {});
    }
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') wakeLock();
    });
    wakeLock();

    // Show the last known state straight away, then catch up.
    var cached = local.getJSON(KEY);
    if (cached && cached.code === CODE) applyState(cached);
    else renderBoard({ totals: {}, segment: 'Setup' }, null);
    if (!client) $('latest').textContent = 'Not connected: check quiz/config.js';

    checkClock();
    setInterval(checkClock, 60000);
    setInterval(tick, 100);
    startLive(fetchState);
    renderChip();
  }

  // ================================================================ keeper
  function keeper() {
    var PIN_KEY = 'sb_keeper_pin_' + CODE;
    var K = {
      pin: session.get(PIN_KEY),
      unlocked: false,
      game: local.get('sb_keeper_game') || GAMES[0].key,
      recent: [],
      busy: {},
      armed: {},
      sign: {},          // Other: '+' or '-' per group
      labelDirty: false,
      toastTimer: null
    };

    // ---------------------------------------------------------------- calls
    function call(fn, args, timeoutMs) {
      var sent = Date.now();
      var a = { p_code: CODE, p_pin: K.pin };
      for (var k in args || {}) a[k] = args[k];
      return rpc(fn, a, timeoutMs || 10000).then(function (r) {
        if (r.network) { setNet(false); return r; }
        setNet(true);
        if (r.error === 'bad_pin' || r.error === 'pin_not_set' || r.error === 'board_not_found') {
          relock(r.message || 'Enter the keeper PIN.');
          return r;
        }
        if (r.data && r.data.server_now) syncClock(r.data.server_now, sent, Date.now());
        if (r.data && r.data.state) {
          K.recent = r.data.recent || [];
          K.fromCall = true;
          applyState(r.data.state);
          K.fromCall = false;
          renderRecent();
        }
        return r;
      });
    }

    // One request at a time per control, and a friendly message on failure.
    function act(key, fn, args) {
      if (K.busy[key]) return Promise.resolve({ error: 'busy' });
      K.busy[key] = true;
      renderBusy();
      return call(fn, args).then(function (r) {
        delete K.busy[key];
        renderBusy();
        if (r.network) toast('No connection. Nothing was saved. Try again.');
        else if (r.error === 'locked') toast(r.message || 'Too many wrong PINs. Wait a minute.');
        else if (r.error && r.error !== 'bad_pin' && r.error !== 'pin_not_set') toast(r.message || 'That did not work.');
        return r;
      });
    }

    // Two taps within 3 seconds for anything hard to take back.
    function armed(name, msg) {
      if (K.armed[name] && K.armed[name] > Date.now()) { delete K.armed[name]; renderArmed(); return true; }
      K.armed = {};
      K.armed[name] = Date.now() + 3000;
      if (msg) toast(msg);
      renderArmed();
      setTimeout(renderArmed, 3100);
      return false;
    }

    // ---------------------------------------------------------------- toast
    function toast(text, undoId) {
      var el = $('toast');
      $('toastText').textContent = text;
      $('toastUndo').hidden = !undoId;
      $('toastUndo').dataset.id = undoId || '';
      el.hidden = false;
      el.classList.remove('show');
      void el.offsetWidth;
      el.classList.add('show');
      clearTimeout(K.toastTimer);
      K.toastTimer = setTimeout(function () { el.hidden = true; }, undoId ? 8000 : 4000);
    }

    // ---------------------------------------------------------------- PIN gate
    function relock(msg) {
      K.unlocked = false;
      K.pin = null;
      session.del(PIN_KEY);
      $('gate').hidden = false;
      $('app').hidden = true;
      $('gateError').textContent = msg || '';
      $('pin').value = '';
    }

    function unlock(pin) {
      K.pin = pin;
      $('gateBtn').disabled = true;
      $('gateError').textContent = '';
      return call('sb_keeper_state').then(function (r) {
        $('gateBtn').disabled = false;
        if (r.data && r.data.state) {
          K.unlocked = true;
          session.set(PIN_KEY, pin);
          $('gate').hidden = true;
          $('app').hidden = false;
          render();
          return;
        }
        if (r.network) $('gateError').textContent = 'No connection. Check the internet and try again.';
        else if (r.error === 'locked') $('gateError').textContent = r.message;
        else if (!$('gateError').textContent) $('gateError').textContent = r.message || 'That did not work.';
        if (!r.data || !r.data.state) { K.pin = null; session.del(PIN_KEY); }
      });
    }

    // ---------------------------------------------------------------- points
    function gameOf(key) {
      for (var i = 0; i < GAMES.length; i++) if (GAMES[i].key === key) return GAMES[i];
      return GAMES[0];
    }

    function renderChips() {
      $('gameChips').innerHTML = GAMES.map(function (g) {
        return '<button type="button" class="gchip' + (g.key === K.game ? ' on' : '') +
          '" data-game="' + esc(g.key) + '" aria-pressed="' + (g.key === K.game) + '">' + esc(g.name) + '</button>';
      }).join('');
    }

    function renderPanel() {
      var g = gameOf(K.game);
      var totals = totalsOf(L.state);
      var html = GROUPS.map(function (name) {
        var head = '<div class="ghead"><span class="gname">' + esc(name) + '</span>' +
          '<span class="gtotal" data-total="' + esc(name) + '">' + num(totals[name]) + '</span></div>';
        var body;
        if (g.buttons) {
          body = '<div class="gbtns">' + g.buttons.map(function (b, i) {
            return '<button type="button" class="award" data-group="' + esc(name) + '" data-btn="' + i + '">' +
              '<b>' + signed(b.points) + '</b><span>' + esc(b.text) + '</span></button>';
          }).join('') + '</div>';
        } else if (g.entry === 'points') {
          body = '<form class="gentry" data-group="' + esc(name) + '">' +
            '<input type="text" inputmode="numeric" pattern="[0-9]*" placeholder="Quiz points" aria-label="Quiz points for ' + esc(name) + '">' +
            '<button type="submit" class="add">Add</button></form>';
        } else if (g.entry === 'count') {
          body = '<form class="gentry" data-group="' + esc(name) + '">' +
            '<input type="text" inputmode="numeric" pattern="[0-9]*" placeholder="Notes" aria-label="Notes for ' + esc(name) + '">' +
            '<span class="calc" data-calc="' + esc(name) + '">× ' + g.perItem + '</span>' +
            '<button type="submit" class="add">Add</button></form>';
        } else {
          var minus = K.sign[name] === '-';
          body = '<form class="gentry other" data-group="' + esc(name) + '">' +
            '<button type="button" class="sign' + (minus ? ' minus' : '') + '" data-sign="' + esc(name) + '" aria-label="Plus or minus">' +
            (minus ? '−' : '+') + '</button>' +
            '<input type="text" inputmode="numeric" pattern="[0-9]*" placeholder="Points" aria-label="Points for ' + esc(name) + '">' +
            '<input type="text" class="reason" maxlength="40" placeholder="Reason" aria-label="Reason for ' + esc(name) + '">' +
            '<button type="submit" class="add">Add</button></form>';
        }
        return '<div class="gcard">' + head + body + '</div>';
      }).join('');
      $('panel').innerHTML = html;
      $('panel').dataset.game = g.key;
      renderBusy();
    }

    function renderTotals() {
      var totals = totalsOf(L.state);
      GROUPS.forEach(function (name) {
        var el = document.querySelector('[data-total="' + name + '"]');
        if (el) el.textContent = num(totals[name]);
      });
    }

    function award(group, points, label, busyKey) {
      if (!points || Math.abs(points) > 10000) { toast('Enter a number between 1 and 10,000.'); return Promise.resolve(null); }
      var g = gameOf(K.game);
      return act(busyKey, 'sb_award', {
        p_group: group, p_points: points, p_game_key: g.key, p_label: label
      }).then(function (r) {
        if (r.data && r.data.award_id) toast(signed(points) + ' ' + group, r.data.award_id);
        return r;
      });
    }

    function undo(id) {
      return act('undo', 'sb_undo', { p_award_id: id ? Number(id) : null }).then(function (r) {
        if (r.data && r.data.note === 'nothing_to_undo') toast(id ? 'That award was already undone.' : 'Nothing to undo.');
        else if (r.data && r.data.undone_id) {
          var a = (K.recent || []).filter(function (x) { return x.id === r.data.undone_id; })[0];
          toast(a ? 'Undone: ' + signed(a.points) + ' ' + a.group : 'Undone.');
        }
      });
    }

    function renderRecent() {
      var list = K.recent || [];
      $('recent').innerHTML = list.length ? list.map(function (a) {
        var t = new Date(ts(a.at) || Date.now());
        var hm = t.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        return '<li class="' + (a.undone ? 'undone' : '') + '"><span class="pts' + (a.points < 0 ? ' neg' : '') + '">' +
          signed(a.points) + '</span><span class="who">' + esc(a.group) + ' <em>' + esc(a.label) + '</em></span>' +
          '<span class="when">' + (a.undone ? 'Undone' : esc(hm)) + '</span></li>';
      }).join('') : '<li class="empty">No awards yet.</li>';
      $('undoLatest').disabled = !list.some(function (a) { return !a.undone; }) || !!K.busy.undo;
    }

    // ---------------------------------------------------------------- timer
    function labelValue() {
      var v = $('timerLabelIn').value.trim();
      return v || (L.state && L.state.segment) || '';
    }

    function setTimer(seconds, key) {
      var s = L.state;
      var phase = timerPhase(s, timerLeft(s));
      if (phase === 'running' && !armed('replace:' + key, 'A timer is running. Tap again to replace it.')) return;
      act('timer:' + key, 'sb_timer', { p_action: 'set', p_seconds: seconds, p_label: labelValue() })
        .then(function (r) { if (!r.error) toast('Timer set to ' + mmss(seconds) + '. Tap Start.'); });
    }

    function timerAct(action) {
      var args = { p_action: action, p_seconds: null, p_label: action === 'start' ? labelValue() : null };
      act('timer:' + action, 'sb_timer', args);
    }

    function renderTimerButtons() {
      var s = L.state;
      var left = timerLeft(s), phase = timerPhase(s, left);
      var dur = s ? Number(s.timer_duration_s) || 0 : 0;
      var dis = {
        start: !(dur > 0) || phase === 'running' || phase === 'paused',
        pause: phase !== 'running',
        resume: phase !== 'paused',
        reset: phase === 'idle' || phase === 'ready',
        add_minute: phase === 'idle'
      };
      Array.prototype.forEach.call(document.querySelectorAll('[data-timer]'), function (b) {
        var a = b.dataset.timer;
        b.disabled = !!dis[a] || !!K.busy['timer:' + a];
      });
    }

    function tickTimer() {
      if (!K.unlocked) return;
      var s = L.state;
      var left = timerLeft(s), phase = timerPhase(s, left);
      var text = phase === 'done' ? 'TIME' : mmss(left);
      $('kTimer').textContent = text;
      $('kTimer').dataset.phase = phase;
      $('kTimerState').textContent = PHASE_TEXT[phase] + ((s && s.timer_label) ? ' · ' + s.timer_label : '');
      $('miniTimer').textContent = phase === 'idle' ? '--:--' : text;
      $('miniTimer').dataset.phase = phase;
      renderTimerButtons();
    }

    // ---------------------------------------------------------------- segment
    function renderSegments() {
      var cur = (L.state && L.state.segment) || '';
      $('segments').innerHTML = SEGMENTS.map(function (s) {
        return '<button type="button" class="seg' + (s === cur ? ' on' : '') + '" data-seg="' + esc(s) +
          '" aria-pressed="' + (s === cur) + '">' + esc(s) + '</button>';
      }).join('');
      $('miniSeg').textContent = cur || 'Setup';
      if (!K.labelDirty) $('timerLabelIn').value = cur;
      $('timerLabelIn').placeholder = cur || 'Label';
    }

    // ---------------------------------------------------------------- render
    function renderBusy() {
      Array.prototype.forEach.call(document.querySelectorAll('.award'), function (b) {
        b.disabled = !!K.busy['award:' + b.dataset.group + ':' + b.dataset.btn];
      });
      Array.prototype.forEach.call(document.querySelectorAll('.gentry .add'), function (b) {
        b.disabled = !!K.busy['entry:' + b.form.dataset.group];
      });
      $('undoLatest').disabled = !(K.recent || []).some(function (a) { return !a.undone; }) || !!K.busy.undo;
      $('resetAll').disabled = !!K.busy.reset;
      renderTimerButtons();
    }

    function renderArmed() {
      var on = K.armed.reset && K.armed.reset > Date.now();
      $('resetAll').classList.toggle('armed', !!on);
      $('resetAll').textContent = on ? 'Tap again to reset all scores' : 'Reset all scores';
    }

    function render() {
      renderChips();
      renderPanel();
      renderRecent();
      renderSegments();
      renderArmed();
      tickTimer();
    }

    var lastSeg = null;
    L.onState = function () {
      if (!K.unlocked) return;
      renderTotals();
      if (L.state.segment !== lastSeg) { lastSeg = L.state.segment; renderSegments(); }
      tickTimer();
      // A newer row that did not come with an award list (realtime, or the
      // other keeper's phone): fetch the list too.
      if (!K.fromCall) refreshSoon();
    };
    var refreshTimer = null;
    function refreshSoon() {
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(function () { if (K.unlocked) call('sb_keeper_state'); }, 300);
    }

    // ---------------------------------------------------------------- events
    $('gameChips').addEventListener('click', function (e) {
      var b = e.target.closest('[data-game]');
      if (!b) return;
      K.game = b.dataset.game;
      local.set('sb_keeper_game', K.game);
      renderChips();
      renderPanel();
    });

    $('panel').addEventListener('click', function (e) {
      var b = e.target.closest('.award');
      if (b) {
        var g = gameOf(K.game), btn = g.buttons[Number(b.dataset.btn)];
        award(b.dataset.group, btn.points, btn.label, 'award:' + b.dataset.group + ':' + b.dataset.btn);
        return;
      }
      var s = e.target.closest('[data-sign]');
      if (s) {
        var name = s.dataset.sign;
        K.sign[name] = K.sign[name] === '-' ? '+' : '-';
        s.classList.toggle('minus', K.sign[name] === '-');
        s.textContent = K.sign[name] === '-' ? '−' : '+';
      }
    });

    $('panel').addEventListener('input', function (e) {
      var f = e.target.closest('.gentry');
      if (!f || e.target.classList.contains('reason')) return;
      e.target.value = e.target.value.replace(/[^0-9]/g, '').slice(0, 5);
      var g = gameOf(K.game);
      if (g.entry === 'count') {
        var n = parseInt(e.target.value, 10) || 0;
        f.querySelector('.calc').textContent = n ? '= ' + signed(n * g.perItem) : '× ' + g.perItem;
      }
    });

    $('panel').addEventListener('submit', function (e) {
      e.preventDefault();
      var f = e.target, group = f.dataset.group, g = gameOf(K.game);
      var input = f.querySelector('input:not(.reason)');
      var n = parseInt(input.value, 10) || 0;
      var points, label;
      if (g.entry === 'points') { points = n; label = g.label; }
      else if (g.entry === 'count') {
        points = n * g.perItem;
        label = g.label + ', ' + n + ' ' + g.unit + (n === 1 ? '' : 's');
      } else {
        points = K.sign[group] === '-' ? -n : n;
        label = f.querySelector('.reason').value.trim() || g.label;
      }
      if (!n) { input.focus(); toast('Type a number first.'); return; }
      award(group, points, label, 'entry:' + group).then(function (r) {
        if (r && r.data && r.data.award_id) {
          f.reset();
          if (g.entry === 'count') f.querySelector('.calc').textContent = '× ' + g.perItem;
          input.blur();
        }
      });
    });

    $('toastUndo').addEventListener('click', function () {
      var id = $('toastUndo').dataset.id;
      $('toast').hidden = true;
      if (id) undo(id);
    });
    $('undoLatest').addEventListener('click', function () { undo(null); });

    $('presets').innerHTML = TIMER_PRESETS.map(function (m) {
      return '<button type="button" data-preset="' + m + '">' + m + ' min</button>';
    }).join('');
    $('presets').addEventListener('click', function (e) {
      var b = e.target.closest('[data-preset]');
      if (b) setTimer(Number(b.dataset.preset) * 60, 'p' + b.dataset.preset);
    });
    $('customForm').addEventListener('submit', function (e) {
      e.preventDefault();
      var m = parseFloat(String($('customMin').value).replace(',', '.'));
      if (!(m > 0) || m > 180) { toast('Enter minutes between 1 and 180.'); return; }
      setTimer(Math.round(m * 60), 'custom');
    });
    $('timerLabelIn').addEventListener('input', function () {
      K.labelDirty = $('timerLabelIn').value.trim() !== '' &&
        $('timerLabelIn').value.trim() !== ((L.state && L.state.segment) || '');
    });
    document.querySelector('.tbtns').addEventListener('click', function (e) {
      var b = e.target.closest('[data-timer]');
      if (b && !b.disabled) timerAct(b.dataset.timer);
    });

    $('segments').addEventListener('click', function (e) {
      var b = e.target.closest('[data-seg]');
      if (!b || (L.state && L.state.segment === b.dataset.seg)) return;
      act('segment', 'sb_segment', { p_segment: b.dataset.seg }).then(function (r) {
        if (!r.error) toast('Now: ' + b.dataset.seg);
      });
    });

    $('resetAll').addEventListener('click', function () {
      if (!armed('reset')) return;
      act('reset', 'sb_reset').then(function (r) {
        if (!r.error) toast('All scores reset to 0.');
      });
    });

    $('gateForm').addEventListener('submit', function (e) {
      e.preventDefault();
      var pin = $('pin').value.trim();
      if (pin && !$('gateBtn').disabled) unlock(pin);
    });
    $('lockBtn').addEventListener('click', function () { relock(''); });

    // ---------------------------------------------------------------- start
    if (!client) $('gateError').textContent = 'Not connected: check quiz/config.js.';
    if (K.pin) unlock(K.pin); else relock('');
    setInterval(tickTimer, 250);
    // The keeper poll also refreshes the award list, so it uses the PIN.
    startLive(function () { return K.unlocked ? call('sb_keeper_state') : fetchState(); });
    checkClock();
    renderChip();
  }

  if (document.body.dataset.page === 'tv') tv(); else keeper();
})();

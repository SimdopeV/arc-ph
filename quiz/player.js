// Player page: join, answer, see results. Listens to one games row.
(function () {
  var Q = window.Quiz;
  var $screen = document.getElementById('screen');
  var $banner = document.getElementById('banner');
  var $who = document.getElementById('who');
  var CODE = Q.cfg.GAME_CODE || 'ARCPH';
  var KEY = 'arcq_player_' + CODE;
  var HKEY = 'arcq_hist_' + CODE;

  var st = {
    playerId: Q.local.get(KEY),
    player: null,
    game: null,
    choice: null, choiceIdx: null,
    lock: null,          // 'sending' | 'locked' | 'late' for question choiceIdx
    sendError: '',
    result: null,
    total: 0,
    final: null,
    channel: null, chanStatus: null, everSubscribed: false, channelAt: 0,
    netOk: true,
    joinGroup: null, joinError: '', joining: false,
    note: '',
    hist: Q.local.getJSON(HKEY), // { pid, ok: {idx: 1|0}, rank: {idx: n} } for streaks and rank moves
    shownRes: null, shownFinal: false, lastBeat: null
  };
  var screenKey = '';
  var screenBase = '';
  var syncTimer = null;
  var syncing = false;
  var calm = false;
  try { calm = window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) {}

  function letter(i) { return Q.LETTERS[i] || '?'; }
  function opts(g) {
    var o = g && g.options;
    if (typeof o === 'string') { try { o = JSON.parse(o); } catch (e) { o = null; } }
    return Array.isArray(o) ? o : [];
  }

  // Phone buzz. Android only (iPhones ignore it), and only after the player has tapped something.
  function buzz(pattern) { try { if (navigator.vibrate) navigator.vibrate(pattern); } catch (e) {} }

  // ---------------------------------------------------------------- streaks and rank moves
  function hist() {
    if (!st.hist || st.hist.pid !== st.playerId) st.hist = { pid: st.playerId, ok: {}, rank: {} };
    return st.hist;
  }
  function noteResult(res, cardMode) {
    if (!res || cardMode) return;
    var h = hist(), i = res.question_idx;
    h.ok[i] = res.answered && res.is_correct ? 1 : 0;
    if (res.rank) h.rank[i] = res.rank;
    Q.local.setJSON(HKEY, h);
  }
  function streak(idx) {
    var h = hist(), n = 0;
    for (var i = idx; i >= 0 && h.ok[i] === 1; i--) n++;
    return n;
  }

  // ---------------------------------------------------------------- server
  function sync() {
    if (!st.playerId || syncing) return Promise.resolve();
    syncing = true;
    var sent = Date.now();
    return Q.rpc('player_sync', { p_player: st.playerId }).then(function (r) {
      syncing = false;
      if (r.network) { st.netOk = false; updateBanner(); return; }
      st.netOk = true;
      var d = r.data || {};
      Q.syncClock(d.server_now, sent, Date.now());
      if (!d.player) {
        Q.local.del(KEY);
        st.playerId = null; st.player = null;
        st.note = 'You were removed or the game was reset. Join again.';
        render(); updateBanner();
        return;
      }
      st.player = d.player;
      takeGame(d.game, true);
      if (d.choice != null && st.game) {
        st.choice = d.choice; st.choiceIdx = st.game.current_index; st.lock = 'locked';
      }
      if (d.total != null) st.total = d.total;
      st.result = d.result || st.result;
      if (d.result && st.game) noteResult(d.result, st.game.card_mode);
      st.final = d.final || null;
      ensureChannel(st.game.id);
      render(); updateBanner();
    });
  }

  function scheduleSync(maxJitter) {
    clearTimeout(syncTimer);
    syncTimer = setTimeout(sync, Math.random() * (maxJitter || 0));
  }

  // Accept a games row unless it is older than the one we have.
  function takeGame(row, fromSync) {
    if (!row) return false;
    if (st.game && Q.ts(row.updated_at) < Q.ts(st.game.updated_at)) return false;
    var prev = st.game;
    st.game = row;
    Q.useGame(row);
    if (row.current_index !== st.choiceIdx) {
      st.choice = null; st.choiceIdx = null; st.lock = null; st.sendError = '';
    }
    if (row.status === 'lobby') { st.hist = null; Q.local.del(HKEY); st.shownRes = null; st.shownFinal = false; }
    if (fromSync) return true;
    var s = row.status;
    var idx = row.current_index;
    if ((s === 'reveal' || s === 'leaderboard') && (!st.result || st.result.question_idx !== idx)) scheduleSync(1500);
    if (s === 'final' && !st.final) scheduleSync(2500);
    if (s === 'lobby' && prev && prev.status !== 'lobby') scheduleSync(3000); // reset: check we still exist
    return true;
  }

  function onRow(row) {
    if (takeGame(row, false)) render();
  }

  function ensureChannel(gameId) {
    if (st.channel || !gameId) return;
    st.channelAt = Date.now();
    st.channel = Q.subscribeGame(gameId, onRow, function (status) {
      var was = st.chanStatus;
      st.chanStatus = status;
      if (status === 'SUBSCRIBED') {
        // Catch up on anything missed while the socket was down.
        if (st.everSubscribed || was !== 'SUBSCRIBED') scheduleSync(st.everSubscribed ? 1500 : 0);
        st.everSubscribed = true;
      }
      updateBanner();
    });
  }

  // Safety net: a slow poll while realtime is up, a fast one while it is down.
  function pollLoop() {
    var live = st.chanStatus === 'SUBSCRIBED' && st.netOk;
    if (st.playerId) sync();
    setTimeout(pollLoop, live ? 15000 : 3000);
  }

  function updateBanner() {
    var down = false;
    if (st.playerId) {
      if (!st.netOk || navigator.onLine === false) down = true;
      else if (st.channel && st.everSubscribed && st.chanStatus !== 'SUBSCRIBED') down = true;
      else if (st.channel && !st.everSubscribed && Date.now() - st.channelAt > 6000) down = true;
    }
    $banner.hidden = !down;
  }

  // ---------------------------------------------------------------- actions
  function join() {
    var input = document.getElementById('name');
    var name = (input ? input.value : '').replace(/\s+/g, ' ').trim();
    if (!name) return showJoinError('Type your name first.');
    if (name.length > 20) return showJoinError('Use 20 characters or fewer.');
    if (Q.nameBlocked(name)) return showJoinError('Please pick a different name.');
    if (!st.joinGroup) return showJoinError('Tap your team.');
    st.joining = true; updateJoinButton(); showJoinError('');
    wakeLock();
    Q.rpc('player_join', { p_code: Q.cfg.GAME_CODE, p_name: name, p_group: st.joinGroup }).then(function (r) {
      st.joining = false;
      if (r.error) {
        updateJoinButton();
        var msg = {
          name_blocked: 'Please pick a different name.',
          name_required: 'Type your name first.',
          name_too_long: 'Use 20 characters or fewer.',
          bad_group: 'The teams have changed. Tap your team again.',
          game_not_found: 'The quiz is not open yet.',
          game_full: 'The quiz is full.'
        }[r.error] || (r.network ? 'No connection. Try again.' : 'Something went wrong. Try again.');
        if (r.error === 'bad_group') refreshSetup();
        return showJoinError(msg);
      }
      st.playerId = r.data.player_id;
      st.note = '';
      Q.local.set(KEY, st.playerId);
      st.player = { id: r.data.player_id, name: r.data.name, group: r.data.group };
      buzz([20, 40, 40]);
      sync();
    });
  }

  function answer(i) {
    var g = st.game;
    if (!g || g.status !== 'question' || st.lock === 'sending' || st.lock === 'locked') return;
    var idx = g.current_index;
    st.choice = i; st.choiceIdx = idx; st.lock = 'sending'; st.sendError = '';
    wakeLock();
    buzz(14);
    render();
    var picked = document.querySelector('.answer.picked');
    if (picked) picked.classList.add('thump');
    var tries = 0;
    (function send() {
      tries++;
      Q.rpc('submit_answer', { p_player: st.playerId, p_question_idx: idx, p_choice: i }, 6000).then(function (r) {
        if (!st.game || st.game.current_index !== idx) return;
        if (!r.error || r.error === 'duplicate') { st.lock = 'locked'; st.netOk = true; }
        else if (r.network && tries < 4) { setTimeout(send, 400 * tries); return; }
        else if (r.network) { st.lock = null; st.choice = null; st.sendError = 'Could not send. Tap again.'; st.netOk = false; }
        else if (r.error === 'player_not_found') { Q.local.del(KEY); st.playerId = null; st.player = null; }
        else if (r.error === 'card_mode') { st.lock = null; st.choice = null; }
        else { st.lock = 'late'; }
        render(); updateBanner();
      });
    })();
  }

  var lock = null;
  function wakeLock() {
    try {
      if (navigator.wakeLock && !lock && document.visibilityState === 'visible') {
        navigator.wakeLock.request('screen').then(function (l) {
          lock = l; l.addEventListener('release', function () { lock = null; });
        }, function () {});
      }
    } catch (e) {}
  }

  // ---------------------------------------------------------------- little effects
  // Confetti from a point on the phone screen. Canvas, no library, gone in two seconds.
  function burst(n, originY) {
    if (calm) return;
    try {
      var COLORS = ['#F3966F', '#942753', '#F3CA94', '#ffffff', '#3ccf91', '#c9a6ff'];
      var c = document.createElement('canvas');
      c.className = 'burst'; c.setAttribute('aria-hidden', 'true');
      var dpr = Math.min(window.devicePixelRatio || 1, 2), W = window.innerWidth, Ht = window.innerHeight;
      c.width = W * dpr; c.height = Ht * dpr;
      var ctx = c.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      document.body.appendChild(c);
      var parts = [];
      for (var i = 0; i < n; i++) {
        var a = -Math.PI / 2 + (Math.random() - 0.5) * 2.6, v = 5 + Math.random() * 9, s = 5 + Math.random() * 6;
        parts.push({ x: W / 2, y: originY, vx: Math.cos(a) * v, vy: Math.sin(a) * v - 2, w: s, h: s * 0.55,
          r: Math.random() * 6.28, vr: (Math.random() - 0.5) * 0.4, c: COLORS[i % COLORS.length] });
      }
      var start = performance.now(), last = start;
      (function frame(now) {
        var dt = Math.min((now - last) / 16.7, 3); last = now;
        ctx.clearRect(0, 0, W, Ht);
        var alpha = Math.max(0, 1 - (now - start - 1300) / 600);
        ctx.globalAlpha = alpha;
        parts.forEach(function (p) {
          p.vx *= Math.pow(0.985, dt); p.vy = p.vy * Math.pow(0.985, dt) + 0.32 * dt;
          p.x += p.vx * dt; p.y += p.vy * dt; p.r += p.vr * dt;
          ctx.save(); ctx.translate(p.x, p.y); ctx.rotate(p.r); ctx.fillStyle = p.c;
          ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h); ctx.restore();
        });
        if (now - start < 1900) requestAnimationFrame(frame);
        else if (c.parentNode) c.parentNode.removeChild(c);
      })(start);
    } catch (e) {}
  }

  // Count a number up from zero (the page already shows the final number, so a redraw is safe).
  function countTo(id, to, ms) {
    var el = document.getElementById(id);
    if (!el || calm || !to) return;
    var start = performance.now();
    (function step(now) {
      var el2 = document.getElementById(id);
      if (!el2) return;
      var t = Math.min(1, (now - start) / ms), e = 1 - Math.pow(1 - t, 3);
      el2.textContent = Q.num(to * e);
      if (t < 1) requestAnimationFrame(step);
    })(start);
  }

  var ICON = {
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    cross: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" aria-hidden="true"><path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/></svg>',
    clock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>'
  };

  // A line under each result. Picked by question number so it stays put when the screen redraws.
  var BANTER = {
    good: ['Onchain and on point.', 'Faster than finality.', 'Certified builder behaviour.', 'That one settled instantly.',
      'Clean. Like a well-tested contract.', 'Deployed and verified.'],
    bad: ['That one reverted.', 'Out of gas on that one.', 'Shake it off. Next block.', 'Even testnets have bad days.',
      'Confidence: mainnet. Accuracy: testnet.'],
    none: ['Transaction timed out.', 'Thumbs still in the mempool?', 'No answer, no points. Tap faster.']
  };
  function banter(kind, idx) {
    var list = BANTER[kind];
    var name = (st.player && st.player.name) || '';
    return Q.esc(list[(idx + name.length) % list.length]);
  }

  // ---------------------------------------------------------------- views
  function keyFor() {
    if (!Q.configured) return 'nocfg';
    if (!st.playerId) return 'join';
    var g = st.game;
    if (!st.player || !g) return 'loading';
    var idx = g.current_index;
    if (g.status === 'lobby') return 'lobby';
    if (g.status === 'question') {
      if (g.card_mode) return 'card:' + idx;
      if (st.choiceIdx === idx && st.lock === 'locked') return 'locked:' + idx + ':' + st.choice;
      if (st.choiceIdx === idx && st.lock === 'sending') return 'sending:' + idx + ':' + st.choice;
      if (st.lock === 'late' || Q.remaining(g) <= 0) return 'late:' + idx;
      return 'open:' + idx + ':' + st.sendError;
    }
    if (g.status === 'reveal' || g.status === 'leaderboard') {
      var have = st.result && st.result.question_idx === idx ? 'y' : 'n';
      return 'res:' + idx + ':' + g.status + ':' + have + ':' + g.card_mode;
    }
    if (g.status === 'final') return 'final:' + (st.final ? 'y' : 'n');
    return 'loading';
  }

  // Screens that are the same moment for the player share a base, so the
  // entrance animation plays once per moment and not on every small redraw.
  function baseOf(key) {
    var p = key.split(':'), k = p[0];
    if (k === 'open' || k === 'sending' || k === 'locked' || k === 'late' || k === 'card') return 'q:' + p[1];
    if (k === 'res') return 'res:' + p[1];
    return k;
  }

  function render() {
    $who.textContent = st.player ? st.player.name + ' · ' + st.player.group : '';
    var key = keyFor();
    if (key === screenKey) { tick(); return; }
    screenKey = key;
    var kind = key.split(':')[0];
    var html = {
      nocfg: viewNoConfig, join: viewJoin, loading: viewLoading, lobby: viewLobby,
      open: viewQuestion, sending: viewQuestion, locked: viewQuestion, late: viewQuestion, card: viewQuestion,
      res: viewResult, final: viewFinal
    }[kind]();
    var base = baseOf(key);
    $screen.classList.toggle('enter', base !== screenBase);
    screenBase = base;
    $screen.innerHTML = html;
    bind(kind);
    tick();
  }

  function viewNoConfig() {
    return '<h1>Quiz not set up yet</h1><p class="lede">The host still needs to add the Supabase settings.</p>';
  }
  function viewLoading() { return '<p class="lede">Loading...</p>'; }

  // Before joining there is no game row yet, so ask for the event name and teams.
  // The typed name survives the redraw.
  function refreshSetup() {
    return Q.fetchSetup().then(function (row) {
      if (!row || st.playerId) return;
      var input = document.getElementById('name');
      var typed = input ? input.value : '';
      if (Q.GROUPS.indexOf(st.joinGroup) < 0) st.joinGroup = null;
      screenKey = '';
      render();
      input = document.getElementById('name');
      if (input && typed) { input.value = typed; input.dispatchEvent(new Event('input')); }
    });
  }

  function viewJoin() {
    var groups = Q.GROUPS.map(function (g) {
      return '<button type="button" class="group-btn" data-group="' + Q.esc(g) + '" aria-pressed="' + (st.joinGroup === g) + '">' + Q.esc(g) + '</button>';
    }).join('');
    var words = ['No', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve'];
    var count = words[Q.GROUPS.length] || String(Q.GROUPS.length);
    return '' +
      '<h1>Join the <span class="grad-text">live quiz</span></h1>' +
      (st.note ? '<p class="lede">' + Q.esc(st.note) + '</p>' : '<p class="lede">' + Q.esc(Q.EVENT) + '. ' + count + ' teams, one winner.</p>') +
      '<form id="joinForm" class="screen" novalidate autocomplete="off">' +
      '  <div class="field"><p class="label"><label for="name">Your name</label></p>' +
      '    <input id="name" name="name" maxlength="20" enterkeyhint="done" autocapitalize="words" spellcheck="false" required>' +
      '    <div class="count" id="count">0 / 20</div></div>' +
      '  <div><p class="label">Your team</p><div class="groups' + (Q.GROUPS.length > 8 ? ' many' : '') + '" role="group" aria-label="Your team">' + groups + '</div></div>' +
      '  <p class="error" id="joinError" role="alert"></p>' +
      '  <button class="primary" id="joinBtn" type="submit">Join</button>' +
      '</form>';
  }

  function viewLobby() {
    return '<div class="waiting">' +
      '<div class="pulse"><i></i><i></i><i></i><b>' + ICON.check + '</b></div>' +
      '<h1>You\'re in, <span class="name">' + Q.esc(st.player.name) + '</span>.</h1>' +
      '<p class="lede">Team ' + Q.esc(st.player.group) + '. Eyes on the big screen.</p>' +
      '<span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>' +
      '</div>' +
      '<p class="lede center">The first question lands here. Keep this page open.</p>';
  }

  function viewQuestion() {
    var g = st.game, idx = g.current_index;
    var o = opts(g);
    var locked = st.choiceIdx === idx && (st.lock === 'locked' || st.lock === 'sending');
    var late = !locked && (st.lock === 'late' || Q.remaining(g) <= 0);
    var cls = (g.card_mode ? 'static' : (locked || late ? 'locked' : '')) + (o.length === 2 ? ' two' : '');
    var buttons = o.map(function (text, i) {
      var picked = locked && st.choice === i ? ' picked' : '';
      var dis = g.card_mode || locked || late ? ' disabled' : '';
      return '<button type="button" class="answer tile t' + i + picked + '" data-choice="' + i + '"' + dis + '>' +
        '<span class="badge">' + letter(i) + '</span><span>' + Q.esc(text) + '</span></button>';
    }).join('');
    var status = '';
    if (g.card_mode) status = '<p class="status-line">Card round. Hold up your team\'s card.</p>';
    else if (st.lock === 'sending' && locked) status = '<p class="status-line">Sending...</p>';
    else if (locked) status = '<p class="status-line">Answer locked. Waiting for everyone.</p>';
    else if (late) status = '<p class="status-line">Time\'s up.</p>';
    else if (st.sendError) status = '<p class="status-line error">' + Q.esc(st.sendError) + '</p>';
    return '' +
      '<div class="qhead"><span class="qmeta">Question ' + (idx + 1) + ' of ' + g.total_questions +
      (g.category ? ' · ' + Q.esc(g.category) : '') +
      (g.points === 'double' ? ' · <b class="pts-tag">Double points</b>' : g.points === 'none' ? ' · <b class="pts-tag none">No points</b>' : '') +
      '</span><span class="timer" id="timer"></span></div>' +
      '<div class="bar"><i id="bar"></i></div>' +
      '<p class="stake" id="stake"></p>' +
      '<p class="qtext">' + Q.esc(g.question_text) + '</p>' +
      '<div class="answers ' + cls + '">' + buttons + '</div>' + status;
  }

  function revealedBox(g) {
    var o = opts(g), r = g.revealed_index;
    if (r == null || !o[r]) return '';
    return '<div><p class="label">Right answer</p>' +
      '<div class="reveal-answer tile t' + r + '"><span class="badge">' + letter(r) + '</span><span>' + Q.esc(o[r]) + '</span></div></div>' +
      (g.explanation ? '<p class="explain">' + Q.esc(g.explanation) + '</p>' : '');
  }

  // "You're 3rd of 28", with how far you moved since the last question.
  function rankLine(res, idx) {
    if (!res || !res.rank || !res.players) return '';
    var prev = hist().rank[idx - 1], mv = '';
    if (prev && prev > res.rank) mv = '<span class="mv up">&#9650; ' + (prev - res.rank) + '</span>';
    else if (prev && prev < res.rank) mv = '<span class="mv">&#9660; ' + (res.rank - prev) + '</span>';
    return '<div class="rankline"><span>You\'re <b>' + Q.ordinal(res.rank) + '</b> of ' + res.players + '</span>' + mv + '</div>';
  }

  function viewResult() {
    var g = st.game, idx = g.current_index;
    var res = st.result && st.result.question_idx === idx ? st.result : null;
    var top, rank = '';
    if (g.card_mode && !(res && res.answered)) {
      top = '<div class="card result"><p class="verdict">Card round</p><p class="total">Your total ' + Q.num(st.total) + '</p></div>';
    } else if (!res) {
      top = '<div class="card result"><p class="lede">Checking your answer<span class="dots" style="margin-left:8px"><i></i><i></i><i></i></span></p></div>';
    } else if (!res.answered) {
      top = '<div class="card result bad"><div class="mark">' + ICON.clock + '</div><p class="verdict">No answer</p>' +
        '<p class="banter">' + banter('none', idx) + '</p><p class="points">+0 points</p>' +
        '<p class="total">Total ' + Q.num(st.total) + '</p></div>';
      rank = rankLine(res, idx);
    } else {
      var chips = '';
      if (res.is_correct) {
        var run = streak(idx);
        if (run >= 2) chips += '<span class="chip-s fire">' + run + ' in a row</span>';
        if (res.points >= 900) chips += '<span class="chip-s">Lightning fast</span>';
        else if (res.points >= 800) chips += '<span class="chip-s">Quick</span>';
      }
      top = '<div class="card result ' + (res.is_correct ? 'good' : 'bad') + '">' +
        '<div class="mark">' + (res.is_correct ? ICON.check : ICON.cross) + '</div>' +
        '<p class="verdict">' + (res.is_correct ? 'Correct' : 'Not quite') + '</p>' +
        '<p class="banter">' + banter(res.is_correct ? 'good' : 'bad', idx) + '</p>' +
        '<p class="points">+<span id="pts">' + Q.num(res.points) + '</span> points</p>' +
        '<div class="chips">' + chips + '</div>' +
        '<p class="total">Total ' + Q.num(st.total) + '</p></div>';
      rank = rankLine(res, idx);
    }
    var foot = g.status === 'leaderboard' ? '<p class="status-line">Leaderboard is on the big screen.</p>' : '';
    return '<p class="qmeta">Question ' + (idx + 1) + ' of ' + g.total_questions + '</p>' + top + rank + revealedBox(g) + foot;
  }

  function viewFinal() {
    var f = st.final;
    if (!f) return '<h1>That\'s a wrap</h1><p class="lede">Loading your results...</p>';
    var top = f.rank <= 3;
    var line = f.group_rank === 1 ? 'Your team won. Take a bow.'
      : top ? 'Top three. Certified builder.' : 'Thanks for playing. Now go build something on Arc Studio.';
    return '' +
      '<h1>That\'s a <span class="grad-text">wrap</span></h1>' +
      '<div class="card final-card' + (top ? ' top' : '') + '"><p class="label">Your rank</p>' +
      '<p class="final-rank">' + Q.ordinal(f.rank) + '<small>of ' + f.players + '</small></p>' +
      '<p class="final-num"><span id="fnum">' + Q.num(st.total) + '</span><small>points</small></p></div>' +
      '<div class="card">' +
      '<div class="final-row" style="border-top:0"><span>Team ' + Q.esc(st.player.group) + '</span><b>' + Q.ordinal(f.group_rank) + ' of ' + f.groups + '</b></div>' +
      '<div class="final-row"><span>Team score</span><b>' + Q.num(f.group_score) + '</b></div>' +
      '</div>' +
      '<p class="lede center">' + line + '</p>';
  }

  // ---------------------------------------------------------------- events
  function showJoinError(msg) {
    st.joinError = msg;
    var el = document.getElementById('joinError');
    if (el) el.textContent = msg;
  }
  function updateJoinButton() {
    var b = document.getElementById('joinBtn');
    if (b) { b.disabled = st.joining; b.textContent = st.joining ? 'Joining...' : 'Join'; }
  }

  // The result has just landed for this question: play it once (pop, count, buzz, confetti).
  function celebrateResult() {
    var g = st.game, idx = g.current_index;
    var res = st.result && st.result.question_idx === idx ? st.result : null;
    if (!res || st.shownRes === idx) return;
    st.shownRes = idx;
    var card = document.querySelector('.result');
    if (card) card.classList.add('show');
    if (g.card_mode && !res.answered) return;
    if (res.answered && res.is_correct) {
      buzz([30, 50, 30, 50, 70]);
      var r = card ? card.getBoundingClientRect() : null;
      burst(streak(idx) >= 3 ? 100 : 60, r ? r.top + 60 : window.innerHeight * 0.3);
      countTo('pts', res.points, 900);
    } else {
      buzz(res.answered ? 200 : [60, 80, 60]);
    }
  }

  function celebrateFinal() {
    var f = st.final;
    if (!f || st.shownFinal) return;
    st.shownFinal = true;
    countTo('fnum', st.total, 1400);
    if (f.rank <= 3 || f.group_rank === 1) {
      buzz([40, 60, 40, 60, 120]);
      burst(120, window.innerHeight * 0.32);
      setTimeout(function () { burst(80, window.innerHeight * 0.32); }, 600);
    }
  }

  function bind(kind) {
    if (kind === 'join') {
      var form = document.getElementById('joinForm');
      var input = document.getElementById('name');
      var count = document.getElementById('count');
      input.addEventListener('input', function () { count.textContent = input.value.length + ' / 20'; });
      form.addEventListener('submit', function (e) { e.preventDefault(); join(); });
      Array.prototype.forEach.call(document.querySelectorAll('.group-btn'), function (b) {
        b.addEventListener('click', function () {
          st.joinGroup = b.getAttribute('data-group');
          Array.prototype.forEach.call(document.querySelectorAll('.group-btn'), function (x) {
            x.setAttribute('aria-pressed', String(x === b));
          });
          buzz(10);
          showJoinError('');
        });
      });
    }
    if (kind === 'open') {
      Array.prototype.forEach.call(document.querySelectorAll('.answer'), function (b) {
        b.addEventListener('click', function () { answer(Number(b.getAttribute('data-choice'))); });
      });
    }
    if (kind === 'res') celebrateResult();
    if (kind === 'final') celebrateFinal();
  }

  // Countdown runs locally from started_at plus the server clock offset.
  function tick() {
    var g = st.game;
    var t = document.getElementById('timer');
    if (!t || !g || g.status !== 'question') { document.body.classList.remove('hurry'); return; }
    var left = Q.remaining(g);
    var shown = Math.max(0, Math.ceil(left));
    var mine = st.choiceIdx === g.current_index && (st.lock === 'locked' || st.lock === 'sending');
    // Last five seconds and no answer yet: the screen edge and the phone beat like a heart.
    var hurry = !g.paused_at && !g.card_mode && !mine && shown > 0 && shown <= 5;
    document.body.classList.toggle('hurry', hurry);
    if (hurry && st.lastBeat !== g.current_index + ':' + shown) {
      st.lastBeat = g.current_index + ':' + shown;
      buzz(shown <= 2 ? [25, 90, 25] : 25);
    }
    t.textContent = g.paused_at ? 'Paused' : String(shown);
    t.className = 'timer' + (hurry ? ' low' : '');
    // Points still up for grabs: 500 + 500 x time left, times the question's points
    // setting (double or none), the same formula the server scores with.
    var stake = document.getElementById('stake');
    if (stake) {
      var sHtml = '', sCls = 'stake';
      if (g.card_mode) sHtml = '';
      else if (mine) { sHtml = '<b>Locked in</b> fingers crossed'; sCls += ' locked'; }
      else if (left > 0 && g.points === 'none') sHtml = '<b>Just for fun</b> no points on this one';
      else if (left > 0) {
        var pts = (500 + Math.round(500 * Math.min(1, left / (g.duration_s || 20)))) * (g.points === 'double' ? 2 : 1);
        sHtml = '<b>+' + Q.num(pts) + '</b> up for grabs' + (g.points === 'double' ? ' · double' : '');
        if (shown <= 5) sCls += ' low';
      }
      if (stake.innerHTML !== sHtml) stake.innerHTML = sHtml;
      stake.className = sCls;
    }
    var bar = document.getElementById('bar');
    if (bar) bar.style.transform = 'scaleX(' + Math.max(0, Math.min(1, left / (g.duration_s || 20))) + ')';
    if (keyFor() !== screenKey) render();
  }

  setInterval(tick, 250);
  setInterval(updateBanner, 2000);
  window.addEventListener('online', function () { sync(); updateBanner(); });
  window.addEventListener('offline', updateBanner);
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') { sync(); wakeLock(); }
  });

  render();
  if (st.playerId) sync(); else refreshSetup();
  setTimeout(pollLoop, 15000);
})();

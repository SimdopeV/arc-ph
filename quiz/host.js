// Host page: runs the quiz on the projector.
// Phone mode: the database is the source of truth and every action is a host_* function.
// Card mode: this page runs the flow from its cached questions and pushes its
// position to the database whenever the internet is up, so it works offline.
(function () {
  var Q = window.Quiz;
  var CODE = Q.cfg.GAME_CODE || 'ARCPH';
  var PLAYER_URL = Q.cfg.PLAYER_URL || 'https://simdopev.github.io/arc-ph/quiz/';
  var K = {
    pin: 'arcq_pin', pinHash: 'arcq_pin_hash_' + CODE, view: 'arcq_host_view_' + CODE,
    qs: 'arcq_host_questions_' + CODE, card: 'arcq_host_card_' + CODE,
    hideScores: 'arcq_hide_team_scores', sound: 'arcq_sound', voice: 'arcq_voice'
  };

  var H = {
    pin: Q.session.get(K.pin),
    view: Q.local.getJSON(K.view),
    questions: Q.local.getJSON(K.qs),
    card: Q.local.getJSON(K.card), // { on, status, index, started_at, paused_at, awards, dirty, posDirty }
    online: false,
    unlocked: false,
    busy: false,
    finalStep: 0,
    manage: false,
    armed: {},
    autoRevealed: {},
    lastHtml: '',
    lastKey: '',          // which screen is up: status, question number, final step
    announceReady: false, // sounds and voice only after the first unlocked draw
    seen: null,           // player ids already shown in the lobby
    lastBeat: '', buzzed: -1,
    podiumShown: false,
    hideScores: Q.local.get(K.hideScores) === 'on', // team scores stay secret until the final results
    qr: null
  };

  var $ = function (id) { return document.getElementById(id); };
  var stage = $('stage');
  if (H.view && H.view.game) Q.useGame(H.view.game); // teams and event name from the last visit

  // ---------------------------------------------------------------- state
  function cardOn() { return !!(H.card && H.card.on); }
  function saveCard() { Q.local.setJSON(K.card, H.card); }
  function opts(g) {
    var o = g && g.options;
    if (typeof o === 'string') { try { o = JSON.parse(o); } catch (e) { o = null; } }
    return Array.isArray(o) ? o : [];
  }

  // The game as shown: the server row, or the local card mode state.
  function game() {
    if (cardOn()) {
      var c = H.card, q = H.questions && H.questions[c.index];
      var shown = c.status === 'reveal' || c.status === 'leaderboard' || c.status === 'final';
      return {
        status: c.status, current_index: c.index, total_questions: H.questions ? H.questions.length : 12,
        duration_s: 20, category: q ? q.category : null, question_text: q ? q.text : null,
        options: q ? q.options : null, started_at: c.started_at, paused_at: c.paused_at,
        revealed_index: shown && q ? q.correct_index : null, explanation: shown && q ? q.explanation : null,
        card_mode: true
      };
    }
    return H.view ? H.view.game : null;
  }
  function players() { return (H.view && H.view.players) || []; }

  // Group score = average member total + 100 per card award. Tie-break: correct answers.
  function standings() {
    var base = {};
    ((H.view && H.view.groups) || []).forEach(function (g) { base[g.name] = g; });
    var awards = H.card ? (H.card.awards || {}) : ((H.view && H.view.card_awards) || {});
    var cards = {};
    Q.GROUPS.forEach(function (g) { cards[g] = 0; });
    Object.keys(awards).forEach(function (k) {
      (awards[k] || []).forEach(function (g) { if (g in cards) cards[g]++; });
    });
    var rows = Q.GROUPS.map(function (name, i) {
      var b = base[name] || {};
      var avg = Number(b.avg) || 0;
      var phoneCorrect = (b.correct || 0) - Math.round((b.card_points || 0) / 100);
      return {
        name: name, order: i, members: b.members || 0, avg: avg, cards: cards[name],
        score: avg + cards[name] * 100, correct: phoneCorrect + cards[name]
      };
    });
    var ranked = rows.slice().sort(function (a, b) {
      return b.score - a.score || b.correct - a.correct || a.order - b.order;
    });
    ranked.forEach(function (r, i) {
      var p = ranked[i - 1];
      r.rank = p && Math.abs(p.score - r.score) < 0.005 && p.correct === r.correct ? p.rank : i + 1;
    });
    return { rows: rows, ranked: ranked };
  }

  // ---------------------------------------------------------------- server calls
  function setOnline(on) {
    if (H.online === on) return;
    H.online = on;
    renderChips();
  }

  function applyView(v) {
    if (!v || !v.game) return;
    var cur = H.view && H.view.game;
    if (cur && cur.id === v.game.id && Q.ts(v.game.updated_at) < Q.ts(cur.updated_at)) return; // older poll
    H.view = v;
    Q.useGame(v.game);
    if (v.game.status !== 'final') H.finalStep = 0;
    Q.local.setJSON(K.view, v);
  }

  function call(fn, args) {
    var sent = Date.now();
    var a = { p_code: CODE, p_pin: H.pin };
    for (var k in args || {}) a[k] = args[k];
    return Q.rpc(fn, a, 10000).then(function (r) {
      if (r.network) { setOnline(false); return r; }
      setOnline(true);
      if (r.error === 'bad_pin' || r.error === 'pin_not_set') { relock(r.error); return r; }
      if (r.error === 'locked') { toast('Too many wrong PINs. Host actions are locked for a minute.'); return r; }
      if (r.data && r.data.server_now) Q.syncClock(r.data.server_now, sent, Date.now());
      if (r.data && r.data.game) applyView(r.data);
      var note = r.data && r.data.note;
      if (note === 'stale') toast('The screen was behind. It is up to date now.');
      if (note === 'cannot_unreveal') toast('The answer is already out. Use Next.');
      if (note === 'no_such_question') toast('No questions loaded. Run questions.local.sql in Supabase.');
      return r;
    });
  }

  function act(fn, args) {
    if (H.busy) return Promise.resolve();
    H.busy = true;
    renderControls();
    return call(fn, args).then(function (r) {
      H.busy = false;
      if (r.network) toast('No connection. Try again, or turn on card mode.');
      render();
      return r;
    });
  }

  function poll() {
    var g = game();
    var delay = g && g.status === 'question' ? 1000 : 2000;
    if (!H.unlocked || !Q.configured) return setTimeout(poll, delay);
    call('host_state').then(function (r) {
      if (!r.network && cardOn() && needsPush()) push();
      render();
      setTimeout(poll, delay);
    });
  }

  function loadQuestions() {
    return call('host_questions').then(function (r) {
      if (r.data && r.data.questions) {
        H.questions = r.data.questions;
        Q.local.setJSON(K.qs, H.questions);
      }
    });
  }

  // ---------------------------------------------------------------- actions
  function armed(name, msg) {
    if (H.armed[name] && H.armed[name] > Date.now()) { delete H.armed[name]; renderControls(); return true; }
    H.armed = {};
    H.armed[name] = Date.now() + 4000;
    if (msg) toast(msg);
    renderControls();
    render();
    setTimeout(function () { renderControls(); render(); }, 4100);
    return false;
  }

  function next() {
    var g = game();
    if (!g || H.busy) return;
    if (g.status === 'final') { if (H.finalStep === 0) { H.finalStep = 1; render(); } return; }
    if (cardOn()) return cardNext();
    if (g.status === 'lobby') return act('host_start');
    if (g.status === 'question') return act('host_reveal', { p_index: g.current_index });
    return act('host_next', { p_from_status: g.status, p_from_index: g.current_index });
  }

  function back() {
    var g = game();
    if (!g || H.busy || g.status === 'lobby') return;
    if (g.status === 'final' && H.finalStep === 1) { H.finalStep = 0; render(); return; }
    if (g.status === 'reveal') { toast('The answer is already out. Use Next.'); return; }
    if (g.status === 'question' && !cardOn() && H.view && H.view.answers_in > 0 &&
        !armed('back', 'Press Back again to cancel this question. Its answers will be deleted.')) return;
    if (cardOn()) return cardBack();
    act('host_back', { p_from_status: g.status, p_from_index: g.current_index });
  }

  function pause() {
    var g = game();
    if (!g || g.status !== 'question') return;
    if (cardOn()) {
      var c = H.card;
      if (c.paused_at) { c.started_at += Q.now() - c.paused_at; c.paused_at = null; }
      else c.paused_at = Q.now();
      saveCard(); render();
      return;
    }
    act('host_pause', { p_index: g.current_index, p_paused: !g.paused_at });
  }

  function end() {
    var g = game();
    if (!g || g.status === 'final') return;
    if (!armed('end', 'Click End quiz again to finish now.')) return;
    if (cardOn()) return cardSet('final', g.current_index);
    act('host_end');
  }

  function reset() {
    if (!armed('reset', 'Click Reset game again. This deletes all players and scores.')) return;
    act('host_reset').then(function (r) {
      if (!r || r.error) { if (r && r.network) toast('Reset needs the internet.'); return; }
      H.card = null; Q.local.del(K.card);
      H.finalStep = 0; H.autoRevealed = {}; H.manage = false;
      toast('Game reset. Back to the lobby.');
      render();
    });
  }

  function removePlayer(id, name) {
    if (!armed('rm:' + id)) return;
    act('host_remove_player', { p_player: id }).then(function (r) {
      if (r && !r.error) toast(name + ' was removed.');
    });
  }

  // ---------------------------------------------------------------- card mode
  function cardSet(status, index) {
    var c = H.card;
    var changed = c.status !== status || c.index !== index;
    if (status === 'question' && changed) { c.started_at = Q.now(); c.paused_at = null; }
    c.status = status; c.index = status === 'lobby' ? -1 : index;
    if (status !== 'final') H.finalStep = 0;
    c.posDirty = true;
    saveCard(); render(); push();
  }
  function cardNext() {
    var c = H.card, total = H.questions.length;
    if (c.status === 'lobby') cardSet('question', 0);
    else if (c.status === 'question') cardSet('reveal', c.index);
    else if (c.status === 'reveal') cardSet('leaderboard', c.index);
    else if (c.status === 'leaderboard') {
      if (c.index + 1 < total) cardSet('question', c.index + 1); else cardSet('final', c.index);
    }
  }
  function cardBack() {
    var c = H.card;
    if (c.status === 'leaderboard') cardSet('reveal', c.index);
    else if (c.status === 'final') cardSet('leaderboard', Math.max(c.index, 0));
    else if (c.status === 'question') {
      if (c.awards[c.index]) { delete c.awards[c.index]; c.dirty[c.index] = true; }
      if (c.index === 0) cardSet('lobby', -1); else cardSet('leaderboard', c.index - 1);
    }
  }
  function toggleAward(group) {
    var c = H.card;
    if (!cardOn() || (c.status !== 'reveal' && c.status !== 'leaderboard')) return;
    var list = (c.awards[c.index] || []).slice();
    var i = list.indexOf(group);
    if (i >= 0) list.splice(i, 1); else list.push(group);
    c.awards[c.index] = list;
    c.dirty[c.index] = true;
    saveCard(); render(); push();
  }

  function needsPush() {
    return !!(H.card && (H.card.posDirty || Object.keys(H.card.dirty || {}).length));
  }
  var pushing = false;
  function push() {
    if (pushing || !H.card || !needsPush() || !Q.configured) return Promise.resolve(true);
    pushing = true;
    var c = H.card;
    var chain = Promise.resolve(true);
    Object.keys(c.dirty).forEach(function (k) {
      chain = chain.then(function (ok) {
        if (!ok) return false;
        var list = (c.awards[k] || []).slice();
        return call('host_card_set', { p_index: Number(k), p_groups: list }).then(function (r) {
          if (r.network || r.error) return false;
          if (JSON.stringify(c.awards[k] || []) === JSON.stringify(list)) delete c.dirty[k];
          return true;
        });
      });
    });
    chain = chain.then(function (ok) {
      if (!ok || !c.posDirty) return ok;
      var s = c.status, i = c.index;
      return call('host_goto', { p_status: s, p_index: s === 'lobby' ? -1 : i }).then(function (r) {
        if (r.network || r.error) return false;
        if (c.status === s && c.index === i) c.posDirty = false;
        return true;
      });
    });
    return chain.then(function (ok) { pushing = false; saveCard(); return ok; });
  }

  function setCardMode(on) {
    var toggle = $('cardToggle');
    if (on) {
      if (!H.questions) {
        toggle.checked = false;
        toast('Card mode needs the questions. Unlock once while online to load them.');
        return;
      }
      var g = H.view && H.view.game;
      var keep = H.card && H.card.awards ? H.card.awards : null;
      H.card = {
        on: true,
        status: g ? g.status : 'lobby',
        index: g ? g.current_index : -1,
        started_at: g && g.started_at ? Q.ts(g.started_at) : Q.now(),
        paused_at: g && g.paused_at ? Q.ts(g.paused_at) : null,
        awards: JSON.parse(JSON.stringify(keep || (H.view && H.view.card_awards) || {})),
        dirty: {}, posDirty: false
      };
      saveCard();
      if (Q.configured) call('host_set_card_mode', { p_on: true });
      toast('Card mode on. Phone answers are off. Teams hold up A, B, C or D.');
      render();
      return;
    }
    if (!cardOn()) { toggle.checked = false; return; } // already off
    if (!H.online) {
      toggle.checked = true;
      toast('Card mode stays on until the internet is back.');
      return;
    }
    push().then(function (ok) {
      if (!ok) return { network: true };
      return call('host_set_card_mode', { p_on: false });
    }).then(function (r) {
      if (r.network || r.error) { toggle.checked = true; toast('Could not reach the server. Card mode is still on.'); return; }
      H.card.on = false; saveCard();
      toast('Card mode off. Phones can answer again.');
      render();
    });
  }

  // ---------------------------------------------------------------- sound
  // Every sound is made in the browser (Web Audio), so there are no audio files
  // to load and it works offline in card mode.
  var sfx = (function () {
    var on = Q.local.get(K.sound) !== 'off';
    var ctx = null, master = null, nbuf = null;

    function ac() {
      if (!on) return null;
      try {
        if (!ctx) {
          var C = window.AudioContext || window.webkitAudioContext;
          if (!C) return null;
          ctx = new C();
          master = ctx.createGain();
          master.gain.value = 0.6;
          master.connect(ctx.destination);
        }
        if (ctx.state === 'suspended') ctx.resume();
        return ctx.state === 'running' ? ctx : null;
      } catch (e) { return null; }
    }
    function tone(freq, at, dur, type, vol, slideTo) {
      var c = ac();
      if (!c) return;
      var o = c.createOscillator(), g = c.createGain(), t = c.currentTime + (at || 0);
      o.type = type || 'sine';
      o.frequency.setValueAtTime(freq, t);
      if (slideTo) o.frequency.exponentialRampToValueAtTime(slideTo, t + dur);
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(vol || 0.2, t + 0.012);
      g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      o.connect(g); g.connect(master);
      o.start(t); o.stop(t + dur + 0.05);
    }
    function noise(at, dur, vol, from, to, q) {
      var c = ac();
      if (!c) return;
      if (!nbuf) {
        nbuf = c.createBuffer(1, c.sampleRate, c.sampleRate);
        var d = nbuf.getChannelData(0);
        for (var i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
      }
      var src = c.createBufferSource(), f = c.createBiquadFilter(), g = c.createGain(), t = c.currentTime + (at || 0);
      src.buffer = nbuf; src.loop = true;
      f.type = 'bandpass'; f.Q.value = q || 1;
      f.frequency.setValueAtTime(from, t);
      if (to) f.frequency.exponentialRampToValueAtTime(to, t + dur);
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(vol, t + Math.min(0.05, dur / 3));
      g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
      src.connect(f); f.connect(g); g.connect(master);
      src.start(t); src.stop(t + dur + 0.05);
    }

    return {
      on: function () { return on; },
      set: function (v) { on = !!v; Q.local.set(K.sound, on ? 'on' : 'off'); if (on) ac(); },
      unlock: function () { ac(); },
      // someone joined
      join: function () { tone(660, 0, 0.1, 'triangle', 0.16); tone(990, 0.08, 0.16, 'triangle', 0.16); },
      // a new screen slides in
      whoosh: function () { noise(0, 0.42, 0.22, 300, 2600, 1.2); },
      // a quiet clock tick for seconds 10 to 6
      tick: function () { tone(1200, 0, 0.04, 'square', 0.035); },
      // heartbeat for the last five seconds: lub-dub, louder as time runs out
      beat: function (left) {
        var v = 0.5 + (5 - Math.max(1, Math.min(5, left))) * 0.09;
        tone(150, 0, 0.16, 'triangle', v, 60);
        tone(120, 0.2, 0.2, 'triangle', v * 0.75, 50);
      },
      // time's up
      buzz: function () { tone(220, 0, 0.55, 'sawtooth', 0.16, 110); tone(110, 0, 0.55, 'square', 0.1, 55); },
      // the right answer lights up
      reveal: function () {
        tone(523, 0, 0.16, 'triangle', 0.22); tone(659, 0.11, 0.16, 'triangle', 0.22);
        tone(784, 0.22, 0.16, 'triangle', 0.22); tone(1047, 0.33, 0.5, 'triangle', 0.24);
      },
      // scores counting up: each tick a little higher
      count: function (i) { tone(520 + Math.min(i, 16) * 45, 0, 0.05, 'square', 0.04); },
      // before the winner: a roll that grows, then a hit
      drumroll: function (dur) {
        for (var t = 0; t < dur; t += 0.055) noise(t, 0.05, 0.05 + 0.22 * (t / dur), 220, 0, 0.7);
        tone(90, dur, 0.5, 'triangle', 0.7, 45);
        noise(dur, 0.9, 0.3, 5000, 1500, 0.5);
      },
      fanfare: function () {
        [523, 659, 784, 1047].forEach(function (f, i) { tone(f, i * 0.13, 0.22, 'triangle', 0.24); });
        [523, 659, 784, 1047, 1319].forEach(function (f) { tone(f, 0.56, 1.5, 'triangle', 0.13); });
      }
    };
  })();

  // ---------------------------------------------------------------- voice
  // The browser's own speech voice reads out questions, answers and winners.
  var voice = (function () {
    var ok = 'speechSynthesis' in window && typeof window.SpeechSynthesisUtterance === 'function';
    var on = Q.local.get(K.voice) !== 'off';
    var chosen = null;

    function choose() {
      if (!ok) return;
      var vs = window.speechSynthesis.getVoices().filter(function (v) { return /^en/i.test(v.lang || ''); });
      var want = [/natural/i, /Google UK English Female/i, /Google US English/i, /aria|jenny|sonia|libby|samantha/i, /zira|hazel|susan/i];
      chosen = null;
      for (var i = 0; i < want.length && !chosen; i++) {
        for (var j = 0; j < vs.length; j++) if (want[i].test(vs[j].name)) { chosen = vs[j]; break; }
      }
      if (!chosen) chosen = vs[0] || null;
    }
    if (ok) {
      choose();
      try { window.speechSynthesis.addEventListener('voiceschanged', choose); } catch (e) {}
    }

    function say(text, flush) {
      if (!ok || !on || !text) return;
      try {
        if (flush) window.speechSynthesis.cancel();
        var u = new window.SpeechSynthesisUtterance(String(text));
        if (chosen) { u.voice = chosen; u.lang = chosen.lang; } else u.lang = 'en-GB';
        u.rate = 1.03; u.pitch = 1.05; u.volume = 1;
        window.speechSynthesis.speak(u);
      } catch (e) {}
    }

    return {
      ok: ok,
      on: function () { return ok && on; },
      set: function (v) {
        on = !!v;
        Q.local.set(K.voice, on ? 'on' : 'off');
        if (!on && ok) { try { window.speechSynthesis.cancel(); } catch (e) {} }
      },
      say: say,
      // Greets new players, unless it is still busy talking.
      welcome: function (list) {
        if (!ok || !on || !list.length) return;
        try { if (window.speechSynthesis.speaking || window.speechSynthesis.pending) return; } catch (e) {}
        var n = list.map(function (p) { return p.name || p.label; });
        if (n.length === 1) say('Welcome, ' + n[0] + '!');
        else if (n.length === 2) say('Welcome, ' + n[0] + ' and ' + n[1] + '!');
        else say('Welcome, ' + n[0] + ', ' + n[1] + ' and ' + (n.length - 2) + (n.length === 3 ? ' other!' : ' others!'));
      }
    };
  })();

  // ---------------------------------------------------------------- views
  function esc(s) { return Q.esc(s); }

  function qrSvg() {
    if (H.qr) return H.qr;
    if (!window.qrcode) return '<p class="qr-url">QR code needs the internet.</p>';
    var qr = window.qrcode(0, 'M');
    qr.addData(PLAYER_URL);
    qr.make();
    var n = qr.getModuleCount(), m = 2, d = '';
    for (var r = 0; r < n; r++) for (var c = 0; c < n; c++) {
      if (qr.isDark(r, c)) d += 'M' + (c + m) + ' ' + (r + m) + 'h1v1h-1z';
    }
    var size = n + m * 2;
    H.qr = '<svg viewBox="0 0 ' + size + ' ' + size + '" role="img" aria-label="QR code for the quiz" shape-rendering="crispEdges">' +
      '<rect width="' + size + '" height="' + size + '" fill="#fff"/><path d="' + d + '" fill="#000"/></svg>';
    return H.qr;
  }

  function viewLobby() {
    var g = game();
    var counts = {};
    Q.GROUPS.forEach(function (name) { counts[name] = 0; });
    var ps = players();
    ps.forEach(function (p) { counts[p.group] = (counts[p.group] || 0) + 1; });
    var groups = Q.GROUPS.map(function (name) {
      return '<div class="lg' + (counts[name] ? ' has' : '') + '" data-g="' + esc(name) + '"><div class="n">' + counts[name] +
        '</div><div class="g">' + esc(name) + '</div></div>';
    }).join('');
    var nTeams = Q.GROUPS.length;
    var cols = nTeams <= 4 ? 2 : nTeams <= 9 ? 3 : nTeams <= 16 ? 4 : 5;
    var names;
    if (H.manage) {
      names = '<div class="names manage">' + (ps.length ? ps.map(function (p) {
        var arm = H.armed['rm:' + p.id] > Date.now();
        return '<button type="button" class="' + (arm ? 'arm' : '') + '" data-remove="' + p.id + '" data-name="' + esc(p.label) + '">' +
          (arm ? 'Remove ' + esc(p.label) + '?' : esc(p.label) + ' · ' + esc(p.group)) + '</button>';
      }).join('') : '<span>No players yet.</span>') + '</div>' +
        '<p class="kicker">Click a name twice to remove that player.</p>';
    } else {
      names = '<div class="names">' + ps.slice(-24).reverse().map(function (p) {
        return '<span data-id="' + p.id + '">' + esc(p.label) + '</span>';
      }).join('') + '</div>';
    }
    var shortUrl = PLAYER_URL.replace(/^https?:\/\//, '').replace(/\/$/, '');
    var total = (g && g.total_questions) || 0;
    return '<section class="lobby">' +
      '<div class="qr-card">' + qrSvg() + '<div class="qr-url">' + esc(shortUrl) + '</div></div>' +
      '<div class="lobby-side">' +
      '  <p class="kicker">Live quiz · ' + total + (total === 1 ? ' question' : ' questions') + ' · ' + ((g && g.duration_s) || 20) + ' seconds each</p>' +
      '  <h1 class="h-big">Scan to <span class="grad-text">join</span></h1>' +
      '  <p class="lobby-total">Type your name and tap your team. <b>' + ps.length + '</b> ' + (ps.length === 1 ? 'player' : 'players') + ' in.</p>' +
      '  <div class="lobby-groups' + (nTeams > 6 ? ' dense' : '') + '" style="grid-template-columns:repeat(' + cols + ',1fr)">' + groups + '</div>' + names +
      '</div></section>';
  }

  // Runs after the lobby is drawn: new names pop in, their team's count bumps,
  // a blip plays and the voice says hello.
  function bump(el) {
    if (!el) return;
    el.classList.remove('bump');
    void el.offsetWidth; // restart the animation
    el.classList.add('bump');
  }
  function patchLobby() {
    var ps = players(), ids = {}, fresh = [];
    ps.forEach(function (p) { ids[p.id] = 1; if (H.seen && !H.seen[p.id]) fresh.push(p); });
    var first = !H.seen;
    H.seen = ids;
    if (first || !fresh.length) return;
    var teams = {};
    fresh.forEach(function (p) {
      teams[p.group] = 1;
      var el = stage.querySelector('.names span[data-id="' + p.id + '"]');
      if (el) { el.classList.add('pop'); setTimeout(function () { el.classList.remove('pop'); }, 1800); }
    });
    Array.prototype.forEach.call(stage.querySelectorAll('.lg'), function (el) {
      if (teams[el.getAttribute('data-g')]) bump(el);
    });
    bump(stage.querySelector('.lobby-total b'));
    if (H.announceReady) { sfx.join(); voice.welcome(fresh); }
  }

  function ring() {
    return '<div class="ring"><svg viewBox="0 0 100 100" aria-hidden="true">' +
      '<defs><linearGradient id="ringGrad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#F3966F"/><stop offset="1" stop-color="#F3CA94"/></linearGradient></defs>' +
      '<circle class="track" cx="50" cy="50" r="44" fill="none" stroke-width="8"/>' +
      '<circle class="prog" id="ringProg" cx="50" cy="50" r="44" fill="none" stroke-width="8" stroke-dasharray="276.46" stroke-dashoffset="0"/>' +
      '</svg><div class="t" id="ringT"></div></div>';
  }

  // One row for up to six teams, two rows beyond that.
  function stripAttr() {
    var n = Q.GROUPS.length;
    var cols = n <= 6 ? n : Math.ceil(n / 2);
    return ' class="gstrip' + (n > 6 ? ' dense' : '') + '" style="grid-template-columns:repeat(' + cols + ',1fr)"';
  }

  function groupStrip(lead) {
    var s = standings();
    var top = s.ranked[0];
    return '<div' + stripAttr() + '>' + s.rows.map(function (r) {
      var isLead = lead && top && r.rank === 1 && r.score > 0;
      return '<div class="gs' + (isLead ? ' lead' : '') + '"><div class="g">' + esc(r.name) + '</div><div class="s">' + Q.num(r.score) + '</div></div>';
    }).join('') + '</div>';
  }

  function cardButtons(g) {
    var picked = (H.card.awards[g.current_index] || []);
    return '<p class="card-hint">Click each team that held up <b>' + Q.LETTERS[g.revealed_index] + '</b>. 100 points each.</p>' +
      '<div' + stripAttr() + '>' + Q.GROUPS.map(function (name) {
        var on = picked.indexOf(name) >= 0;
        return '<button type="button" class="gs" data-award="' + esc(name) + '" aria-pressed="' + on + '">' +
          '<div class="g">' + esc(name) + '</div><div class="s">' + (on ? '+100' : '0') + '</div></button>';
      }).join('') + '</div>';
  }

  // Share of phone answers that were right, or null when there is nothing to show.
  function pctRight(g) {
    var dist = g.card_mode ? null : (H.view && H.view.distribution);
    if (!dist || g.revealed_index == null) return null;
    var total = dist.reduce(function (a, b) { return a + b; }, 0);
    return total ? Math.round((dist[g.revealed_index] || 0) / total * 100) : null;
  }

  function viewQuestion(g) {
    var o = opts(g);
    var revealed = g.status !== 'question';
    var dist = !revealed || g.card_mode ? null : (H.view && H.view.distribution);
    var totalVotes = dist ? dist.reduce(function (a, b) { return a + b; }, 0) : 0;
    var tiles = o.map(function (t, i) {
      var cls = 'htile tile t' + i + (revealed ? (i === g.revealed_index ? ' right' : ' dim') : '');
      var bar = '';
      if (dist) {
        var pct = totalVotes ? Math.round(dist[i] / totalVotes * 100) : 0;
        bar = '<div class="dist"><span class="track"><span class="fill" style="width:' + pct + '%"></span></span><b>' + dist[i] + '</b></div>';
      }
      return '<div class="' + cls + '"><div class="row"><span class="badge">' + Q.LETTERS[i] + '</span>' +
        '<span class="txt">' + esc(t) + '</span></div>' + bar + '</div>';
    }).join('');

    var foot, chip = '';
    if (!revealed) {
      // The live numbers are filled in by patchLive, so new answers never redraw the screen.
      var left = g.card_mode
        ? '<span>Card round. Teams, get your ' + Q.LETTERS.slice(0, o.length).join(', ') + ' cards ready.</span>'
        : '<span>Answers in: <b id="ansIn"></b></span>';
      foot = '<div class="q-foot">' + left + '<span class="muted" id="qStatus"></span>' +
        (g.card_mode ? '' : '<div class="tcounts" id="tcounts"></div>') + '</div>';
    } else {
      var right = pctRight(g);
      if (right !== null) chip = '<span class="pct' + (right < 40 ? ' low' : '') + '">' + right + '% got it</span>';
      foot = (g.explanation ? '<p class="explain-big">' + esc(g.explanation) + '</p>' : '') +
        (g.card_mode && g.status === 'reveal' ? cardButtons(g) : (H.hideScores ? '' : groupStrip(true)));
    }

    return '<section class="' + (revealed ? 'is-reveal' : 'is-question') + '">' +
      '<div class="q-top"><div>' +
      '  <div class="q-meta"><span class="num">Question ' + (g.current_index + 1) + ' of ' + g.total_questions + '</span>' +
      (g.category ? '<span class="cat">' + esc(g.category) + '</span>' : '') + chip + '</div>' +
      '  <h1 class="q-text">' + esc(g.question_text) + '</h1>' +
      '</div>' + (revealed ? '' : ring()) + '</div>' +
      '<div class="tiles">' + tiles + '</div>' + foot +
      '</section>';
  }

  // Who has answered, team by team, while the question is open.
  function patchLive(g) {
    if (!g || g.status !== 'question' || g.card_mode) return;
    var ps = players();
    var el = $('ansIn'), box = $('tcounts');
    var txt = ((H.view && H.view.answers_in) || 0) + ' / ' + ps.length;
    if (el && el.textContent !== txt) {
      var had = el.textContent !== '';
      el.textContent = txt;
      if (had) bump(el);
    }
    var by = H.view && H.view.team_answers;
    if (!box || !by) return;
    var mem = {};
    ps.forEach(function (p) { mem[p.group] = (mem[p.group] || 0) + 1; });
    var html = Q.GROUPS.filter(function (name) { return mem[name]; }).map(function (name) {
      var a = by[name] || 0;
      return '<span class="tc' + (a >= mem[name] ? ' all' : a ? ' some' : '') + '">' + esc(name) + ' <b>' + a + '/' + mem[name] + '</b></span>';
    }).join('');
    if (box.getAttribute('data-html') !== html) { box.innerHTML = html; box.setAttribute('data-html', html); }
  }

  // The question types itself out when it first appears. Time based, so it
  // lands in the same place even if the screen is redrawn half way.
  var typer = { key: '', t0: 0, timer: 0 };
  function typeStep() {
    var g = game(), el = stage.querySelector('.is-question .q-text');
    if (!el || !g || typer.key !== H.lastKey) { clearInterval(typer.timer); typer.timer = 0; return; }
    var full = String(g.question_text || '');
    var per = Math.min(28, 2400 / Math.max(full.length, 1));
    var n = Math.floor((performance.now() - typer.t0) / per);
    if (n >= full.length) { el.textContent = full; clearInterval(typer.timer); typer.timer = 0; return; }
    if (el.getAttribute('data-n') === String(n)) return;
    el.setAttribute('data-n', String(n));
    el.innerHTML = esc(full.slice(0, n)) + '<span class="tw-rest">' + esc(full.slice(n)) + '</span>';
  }
  function typeStart(key) {
    typer.key = key; typer.t0 = performance.now();
    clearInterval(typer.timer);
    typer.timer = setInterval(typeStep, 30);
    typeStep();
  }

  // ---------------------------------------------------------------- leaderboard
  // What everyone had before this question, worked out from the points gained
  // on it. That is what lets the board show the climb.
  function prevPlayers() {
    var list = players().map(function (p) { return { id: p.id, prev: (p.total || 0) - (p.gained || 0) }; });
    var by = {};
    list.forEach(function (x) {
      var better = 0;
      list.forEach(function (y) { if (y.prev > x.prev) better++; });
      by[x.id] = { total: x.prev, rank: better + 1 };
    });
    return { any: list.some(function (x) { return x.prev > 0; }), by: by };
  }
  function prevTeams(s, g) {
    var gain = {}, mem = {};
    players().forEach(function (p) {
      gain[p.group] = (gain[p.group] || 0) + (p.gained || 0);
      mem[p.group] = (mem[p.group] || 0) + 1;
    });
    var awards = H.card ? (H.card.awards || {}) : ((H.view && H.view.card_awards) || {});
    var now = awards[g.current_index] || [];
    var list = s.ranked.map(function (r) {
      var got = (mem[r.name] ? gain[r.name] / mem[r.name] : 0) + (now.indexOf(r.name) >= 0 ? 100 : 0);
      return { name: r.name, gain: got, prev: r.score - got };
    });
    var by = {};
    list.forEach(function (x) {
      var better = 0;
      list.forEach(function (y) { if (y.prev > x.prev + 0.005) better++; });
      by[x.name] = { total: x.prev, rank: better + 1, gain: x.gain };
    });
    return { any: list.some(function (x) { return x.prev > 0.005; }), by: by };
  }

  // One row. The HTML always holds the final numbers; animateBoards winds them
  // back and plays them forward when the board first appears.
  function boardRow(o) {
    var mv = o.move > 0 ? '<span class="mv up">&#9650; ' + o.move + '</span>'
      : o.move < 0 ? '<span class="mv">&#9660; ' + (-o.move) + '</span>' : '';
    return '<div class="lrow' + (o.first ? ' first' : '') + '"' +
      (o.anim ? ' data-prev="' + o.prevKey + '"' + (o.prevRank ? ' data-prev-rank="' + o.prevRank + '"' : '') : '') + '>' +
      '<span class="r">' + o.rank + '</span>' +
      '<span class="nm">' + o.name + '<small>' + o.sub + '</small></span>' + mv +
      '<span class="sc">' + (o.anim && o.gain >= 0.5 ? '<span class="gain">+' + Q.num(o.gain) + '</span>' : '') +
      (o.anim ? '<span class="cnt" data-from="' + o.from + '" data-to="' + o.to + '">' : '<span>') + Q.num(o.to) + '</span></span></div>';
  }

  function playerRows(list, compact, anim) {
    if (!list.length) return '<p class="kicker">No phone scores yet.</p>';
    var pv = anim ? prevPlayers() : null;
    return '<div class="list' + (compact ? ' compact' : '') + '"' + (anim ? ' data-anim' : '') + '>' + list.map(function (p, i) {
      var b = pv && pv.by[p.id];
      var moved = !!(b && pv.any);
      return boardRow({
        first: i === 0, rank: p.rank, name: esc(p.label), sub: esc(p.group), anim: anim,
        to: p.total || 0, from: b ? b.total : (p.total || 0), gain: p.gained || 0,
        prevKey: (b ? b.rank : 0) * 1000 + i, prevRank: moved ? b.rank : 0, move: moved ? b.rank - p.rank : 0
      });
    }).join('') + '</div>';
  }

  function groupRows(ranked, compact, pv) {
    return '<div class="list' + (compact ? ' compact' : '') + '"' + (pv ? ' data-anim' : '') + '>' + ranked.map(function (r, i) {
      var b = pv && pv.by[r.name];
      var moved = !!(b && pv.any);
      return boardRow({
        first: i === 0, rank: r.rank, name: esc(r.name), sub: r.members + (r.members === 1 ? ' player' : ' players'), anim: !!pv,
        to: r.score, from: b ? b.total : r.score, gain: b ? b.gain : 0,
        prevKey: (b ? b.rank : 0) * 1000 + i, prevRank: moved ? b.rank : 0, move: moved ? b.rank - r.rank : 0
      });
    }).join('') + '</div>';
  }

  function viewLeaderboard(g) {
    var s = standings();
    // With many teams the board shows the top eight; everyone is on the final podium screen.
    var cut = s.ranked.length > 8;
    var shown = cut ? s.ranked.slice(0, 8) : s.ranked;
    return '<section class="is-board">' +
      '<p class="kicker">After question ' + (g.current_index + 1) + ' of ' + g.total_questions + '</p>' +
      '<h1 class="h-mid">Leaderboard</h1>' +
      '<div class="boards">' +
      '  <div><p class="kicker" style="margin-bottom:1.4vh">Top players</p>' + playerRows(players().slice(0, 5), false, true) + '</div>' +
      '  <div><p class="kicker" style="margin-bottom:1.4vh">' + (cut ? 'Top 8 teams' : 'Teams') + '</p>' + (H.hideScores
        ? '<p class="scores-hidden">Team scores are <b>top secret</b> until the final results.</p>'
        : groupRows(shown, shown.length > 5, prevTeams(s, g))) + '</div>' +
      '</div></section>';
  }

  // Plays the board in: rows arrive in their old order with their old scores,
  // the scores count up, then the rows slide to their new places.
  var boardTimer = 0;
  function animateBoards(key, loud) {
    var lists = Array.prototype.slice.call(stage.querySelectorAll('.list[data-anim]'));
    clearInterval(boardTimer);
    if (!lists.length) return;
    var moved = false;
    lists.forEach(function (list) {
      var rows = Array.prototype.slice.call(list.children);
      var pitch = rows.length > 1 ? rows[1].offsetTop - rows[0].offsetTop : 0;
      var old = rows.slice().sort(function (a, b) { return Number(a.getAttribute('data-prev')) - Number(b.getAttribute('data-prev')); });
      list.classList.add('pre');
      old.forEach(function (row, i) {
        var cur = rows.indexOf(row);
        if (cur !== i) moved = true;
        row.style.translate = '0 ' + ((i - cur) * pitch) + 'px';
        var r = row.querySelector('.r'), c = row.querySelector('.cnt');
        r.setAttribute('data-now', r.textContent);
        if (row.getAttribute('data-prev-rank')) r.textContent = row.getAttribute('data-prev-rank');
        if (c) c.textContent = Q.num(Number(c.getAttribute('data-from')));
      });
    });
    var t0 = performance.now(), lastTick = -1, settled = false;
    boardTimer = setInterval(function () {
      if (H.lastKey !== key) { clearInterval(boardTimer); return; }
      var t = performance.now() - t0;
      var p = Math.max(0, Math.min(1, (t - 900) / 1400)), e = 1 - Math.pow(1 - p, 3);
      var climbing = false;
      Array.prototype.forEach.call(stage.querySelectorAll('.cnt[data-from]'), function (c) {
        var a = Number(c.getAttribute('data-from')), b = Number(c.getAttribute('data-to'));
        if (Math.round(a) !== Math.round(b)) climbing = true;
        var txt = Q.num(a + (b - a) * e);
        if (c.textContent !== txt) c.textContent = txt;
      });
      if (loud && climbing && p > 0 && p < 1) {
        var k = Math.floor((t - 900) / 95);
        if (k !== lastTick) { lastTick = k; sfx.count(k); }
      }
      if (t >= 2500 && !settled) {
        settled = true;
        lists.forEach(function (list) {
          list.classList.remove('pre');
          Array.prototype.forEach.call(list.children, function (row) {
            row.style.transition = 'translate .9s cubic-bezier(.2, .8, .2, 1), background .5s ease, border-color .5s ease, box-shadow .5s ease';
            row.style.translate = '0 0';
            var r = row.querySelector('.r');
            if (r && r.getAttribute('data-now')) r.textContent = r.getAttribute('data-now');
          });
        });
        if (loud) {
          if (moved) sfx.whoosh();
          var g = game();
          if (g) voice.say(leaderLine(g), true);
        }
      }
      if (t >= 3800) clearInterval(boardTimer);
    }, 33);
  }

  function leaderLine(g) {
    var ps = players();
    if (ps.length && ps[0].total > 0) {
      var pv = prevPlayers(), top = ps[0], was = pv.by[top.id];
      var name = top.name || top.label;
      if (!pv.any) return name + ' takes the early lead!';
      return was && was.rank === 1 ? name + ' is still on top.' : name + ' takes the lead!';
    }
    if (!H.hideScores) {
      var first = standings().ranked[0];
      if (first && first.score > 0) return 'Team ' + first.name + ' is in front.';
    }
    return '';
  }

  function viewFinal() {
    var s = standings();
    if (H.finalStep === 1) {
      return '<section class="is-top"><p class="kicker">Final results</p><h1 class="h-big">Top <span class="grad-text">players</span></h1>' +
        playerRows(players().slice(0, 5), false, false) + '</section>';
    }
    var r = s.ranked;
    function pod(row, place) {
      if (!row) return '<div></div>';
      return '<div class="pod p' + place + '"><div class="nm">' + esc(row.name) + '</div>' +
        '<div class="sc">' + Q.num(row.score) + ' points</div><div class="block">' + row.rank + '</div></div>';
    }
    var winners = r.filter(function (x) { return x.rank === 1; }).map(function (x) { return x.name; });
    return '<section class="is-final"><p class="kicker">Final results</p>' +
      '<h1 class="h-big win-title">' + (winners.length > 1 ? 'Joint winners: ' : 'Winning team: ') +
      '<span class="grad-text">' + esc(winners.join(' and ')) + '</span></h1>' +
      '<div class="podium">' + pod(r[1], 2) + pod(r[0], 1) + pod(r[2], 3) + '</div>' +
      '<div class="rest' + (r.length > 6 ? ' dense' : '') + '">' + r.slice(3).map(function (x) {
        return '<div class="lrow"><span class="r">' + x.rank + '</span><span class="nm">' + esc(x.name) + '</span><span class="sc">' + Q.num(x.score) + '</span></div>';
      }).join('') + '</div></section>';
  }


  // ---------------------------------------------------------------- confetti
  // Plays once each time the winners' podium comes up: two cannons from the
  // bottom corners, then a short shower from the top. It ignores the laptop's
  // reduced motion setting on purpose: it is for the room, not the laptop owner.
  var confetti = (function () {
    var COLORS = ['#F3966F', '#942753', '#F3CA94', '#ffffff', '#c9a6ff'];
    var canvas = null, ctx = null, parts = [], raf = 0, last = 0, showerUntil = 0, W = 0, Ht = 0;

    function size() {
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = window.innerWidth; Ht = window.innerHeight;
      canvas.width = W * dpr; canvas.height = Ht * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    function add(x, y, angle, spread, speed) {
      var a = angle + (Math.random() - 0.5) * spread;
      var v = speed * (0.55 + Math.random() * 0.6);
      var s = Ht * (0.008 + Math.random() * 0.008);
      parts.push({
        x: x, y: y, vx: Math.cos(a) * v, vy: Math.sin(a) * v,
        w: s, h: s * (0.4 + Math.random() * 0.5),
        rot: Math.random() * 6.28, vr: (Math.random() - 0.5) * 0.3,
        tilt: Math.random() * 6.28, vt: 0.05 + Math.random() * 0.12,
        c: COLORS[Math.floor(Math.random() * COLORS.length)]
      });
    }
    function frame(now) {
      var dt = Math.min((now - last) / 16.7, 3), g = Ht * 0.0006, drag = Math.pow(0.985, dt);
      last = now;
      if (now < showerUntil) for (var k = 0; k < 3; k++) add(Math.random() * W, -20, Math.PI / 2, 1, Ht * 0.004);
      ctx.clearRect(0, 0, W, Ht);
      parts = parts.filter(function (p) {
        p.vx *= drag; p.vy = p.vy * drag + g * dt;
        p.tilt += p.vt * dt; p.rot += p.vr * dt;
        p.x += (p.vx + Math.sin(p.tilt) * 0.6) * dt; p.y += p.vy * dt;
        if (p.y > Ht + 30) return false;
        ctx.save();
        ctx.translate(p.x, p.y); ctx.rotate(p.rot); ctx.scale(1, Math.cos(p.tilt));
        ctx.fillStyle = p.c; ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h);
        ctx.restore();
        return true;
      });
      if (parts.length || now < showerUntil) raf = requestAnimationFrame(frame); else stop();
    }
    function start() {
      if (!canvas) {
        canvas = document.createElement('canvas');
        canvas.className = 'confetti'; canvas.setAttribute('aria-hidden', 'true');
        ctx = canvas.getContext('2d');
        window.addEventListener('resize', function () { if (raf) size(); });
      }
      stop();
      document.body.appendChild(canvas);
      size();
      for (var i = 0; i < 140; i++) {
        add(0, Ht, -Math.PI / 3, 0.6, Ht * 0.034);
        add(W, Ht, -2 * Math.PI / 3, 0.6, Ht * 0.034);
      }
      last = performance.now(); showerUntil = last + 3500;
      raf = requestAnimationFrame(frame);
    }
    function stop() {
      if (raf) cancelAnimationFrame(raf);
      raf = 0; parts = []; showerUntil = 0;
      if (canvas && canvas.parentNode) { ctx.clearRect(0, 0, W, Ht); canvas.parentNode.removeChild(canvas); }
    }
    return { start: start, stop: stop };
  })();

  function screenKey(g) {
    return g ? g.status + ':' + g.current_index + ':' + (g.status === 'final' ? H.finalStep : 0) : '';
  }

  // What happens once when a screen first comes up. `loud` is false for the
  // very first draw after unlocking, so a page reload never shouts.
  function onEnter(g, key, loud) {
    if (!g) return;
    if (g.status === 'question') {
      typeStart(key);
      if (loud) {
        sfx.whoosh();
        var last = g.total_questions > 1 && g.current_index + 1 === g.total_questions;
        voice.say((last ? 'Final question. ' : 'Question ' + (g.current_index + 1) + '. ') + (g.question_text || ''), true);
      }
    } else if (g.status === 'reveal') {
      if (!loud) return;
      sfx.reveal();
      var o = opts(g), i = g.revealed_index;
      if (i == null || !o[i]) return;
      var right = pctRight(g);
      var line = 'The answer is ' + (o.length > 2 ? Q.LETTERS[i] + '. ' : '') + o[i] + '.';
      if (g.card_mode) line += ' Cards up!';
      else if (right !== null) line += right >= 80 ? ' Sharp room!' : right <= 25 ? ' Ouch. That one stung.' : ' ' + right + ' percent got it.';
      voice.say(line, true);
    } else if (g.status === 'leaderboard') {
      animateBoards(key, loud);
    } else if (g.status === 'final' && H.finalStep === 1 && loud) {
      var top = players()[0];
      sfx.reveal();
      if (top && top.total > 0) voice.say('And your top player: ' + (top.name || top.label) + '!', true);
    }
  }

  var podiumTimer = 0;
  function render() {
    var g = game();
    var html;
    if (!g) html = '<section><p class="kicker">Loading the game...</p></section>';
    else if (g.status === 'lobby') html = viewLobby();
    else if (g.status === 'question' || g.status === 'reveal') html = viewQuestion(g);
    else if (g.status === 'leaderboard') html = viewLeaderboard(g);
    else html = viewFinal();

    var ev = $('eventName');
    if (ev.textContent !== Q.EVENT) ev.textContent = Q.EVENT;
    var key = screenKey(g);
    var fresh = key !== H.lastKey;
    var loud = fresh && H.announceReady;
    if (H.unlocked && g) H.announceReady = true;
    H.lastKey = key;
    if (html !== H.lastHtml || fresh) {
      stage.innerHTML = html;
      H.lastHtml = html;
      // Entrance animations hang off .enter, so a data refresh never replays them.
      if (fresh && stage.firstElementChild) stage.firstElementChild.classList.add('enter');
    }
    if (fresh) onEnter(g, key, loud);
    if (g && g.status === 'lobby') patchLobby();
    patchLive(g);

    // The podium builds for a moment, then the confetti and fanfare land with the winner.
    var podium = !!g && g.status === 'final' && H.finalStep === 0;
    if (podium && !H.podiumShown) {
      clearTimeout(podiumTimer);
      podiumTimer = setTimeout(function () {
        if (!H.podiumShown) return;
        confetti.start();
        if (loud) sfx.fanfare();
      }, 2600);
      if (loud) {
        sfx.drumroll(2.5);
        var winners = standings().ranked.filter(function (x) { return x.rank === 1; }).map(function (x) { return x.name; });
        setTimeout(function () {
          if (!H.podiumShown) return;
          voice.say(winners.length > 1
            ? 'It is a tie! ' + winners.join(' and ') + ' share the win!'
            : 'And the winning team is... Team ' + winners[0] + '!', true);
        }, 900);
      }
    } else if (!podium && H.podiumShown) {
      clearTimeout(podiumTimer);
      confetti.stop();
    }
    H.podiumShown = podium;
    renderControls();
    renderChips();
    tick();
  }

  function renderChips() {
    var chip = $('connChip');
    chip.className = 'chip ' + (H.online ? 'live' : 'off');
    chip.lastChild.textContent = H.online ? 'Live' : (Q.configured ? 'Offline' : 'Not set up');
    $('cardChip').hidden = !cardOn();
    $('cardBanner').hidden = !cardOn();
  }

  function renderControls() {
    var g = game();
    var s = g ? g.status : 'lobby';
    var next = $('nextBtn');
    var labels = { lobby: 'Start quiz', question: 'Reveal', reveal: 'Leaderboard' };
    if (s === 'leaderboard') next.textContent = g.current_index + 1 < g.total_questions ? 'Next question' : 'Final results';
    else if (s === 'final') next.textContent = H.finalStep === 0 ? 'Top players' : 'Finished';
    else next.textContent = labels[s];
    next.disabled = H.busy || !g || (s === 'final' && H.finalStep === 1);
    var p = $('pauseBtn');
    p.disabled = H.busy || s !== 'question';
    p.textContent = g && g.paused_at && s === 'question' ? 'Resume' : 'Pause';
    var now = Date.now();
    $('endBtn').textContent = H.armed.end > now ? 'Click again to end' : 'End quiz';
    $('endBtn').className = H.armed.end > now ? 'arm' : '';
    $('endBtn').disabled = H.busy || !g || s === 'final';
    $('resetBtn').textContent = H.armed.reset > now ? 'Click again to reset' : 'Reset game';
    $('resetBtn').className = H.armed.reset > now ? 'arm' : '';
    $('manageBtn').hidden = s !== 'lobby';
    $('manageBtn').setAttribute('aria-pressed', String(H.manage));
    $('questionsBtn').hidden = s !== 'lobby' || cardOn(); // the quiz can only be changed before it starts
    $('setupBtn').hidden = s !== 'lobby' || cardOn();
    $('scoresBtn').setAttribute('aria-pressed', String(H.hideScores));
    $('scoresBtn').textContent = H.hideScores ? 'Team scores hidden' : 'Team scores shown';
    $('soundBtn').setAttribute('aria-pressed', String(sfx.on()));
    $('soundBtn').textContent = sfx.on() ? 'Sound on' : 'Sound off';
    $('voiceBtn').hidden = !voice.ok;
    $('voiceBtn').setAttribute('aria-pressed', String(voice.on()));
    $('voiceBtn').textContent = voice.on() ? 'Voice on' : 'Voice off';
    $('cardToggle').checked = cardOn();
    var armedCard = H.armed.card > now;
    var sw = $('cardToggle').parentNode;
    sw.className = 'switch' + (armedCard ? ' arm' : '') + (cardOn() ? ' on' : '');
    sw.lastChild.textContent = armedCard ? 'Click again for card mode' : 'Card mode';
  }

  // Timer ring, heartbeat, status line and auto-reveal at time up (after the 1 second grace).
  function tick() {
    var g = game();
    if (!g || g.status !== 'question') {
      if (H.lastBeat) { H.lastBeat = ''; document.body.classList.remove('hurry'); }
      return;
    }
    var left = Q.remaining(g);
    var t = $('ringT'), prog = $('ringProg'), st = $('qStatus');
    var shown = Math.max(0, Math.ceil(left));
    if (t) {
      t.textContent = g.paused_at ? 'Paused' : String(shown);
      t.className = 't' + (g.paused_at ? ' small' : '');
    }
    if (prog) prog.setAttribute('stroke-dashoffset', String(276.46 * (1 - Math.max(0, Math.min(1, left / (g.duration_s || 20))))));

    // Last five seconds: the ring and the edge of the screen beat like a heart.
    var low = !g.paused_at && left > 0 && left <= 5;
    document.body.classList.toggle('hurry', low);
    if (t && t.parentNode) t.parentNode.classList.toggle('low', low);
    var beat = g.current_index + ':' + shown;
    if (!g.paused_at && left > 0 && left <= 10 && beat !== H.lastBeat) {
      if (H.announceReady) { if (low) sfx.beat(shown); else sfx.tick(); }
    }
    H.lastBeat = beat;
    if (!g.paused_at && left <= 0 && H.buzzed !== g.current_index) {
      if (H.announceReady && left > -1.5) sfx.buzz();
      H.buzzed = g.current_index;
    }
    if (left > 0 && H.buzzed === g.current_index) H.buzzed = -1; // the question was restarted

    if (st) {
      var all = !g.card_mode && players().length > 0 && H.view && H.view.answers_in >= players().length;
      st.textContent = g.paused_at ? 'Timer paused' : left <= 0 ? (g.card_mode ? 'Time\'s up. Cards up!' : 'Time\'s up')
        : all ? 'Everyone has answered' : '';
    }
    if (!g.card_mode && !g.paused_at && left <= -1 && !H.autoRevealed[g.current_index] && !H.busy) {
      H.autoRevealed[g.current_index] = true;
      act('host_reveal', { p_index: g.current_index });
    }
  }


  var toastTimer;
  function toast(msg) {
    var el = $('toast');
    el.textContent = msg;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.hidden = true; }, 3800);
  }

  // ---------------------------------------------------------------- question picker
  // The bank lives in the database (private, read with the PIN). The host ticks
  // the questions for this quiz, puts them in order and saves. Lobby only.
  var P = {
    open: false, bank: null, sel: [], saved: [], unlinked: 0, filter: 'All', search: '',
    answers: false, openId: null, loading: false, err: '', msg: '', armClose: 0
  };

  function pkDirty() { return P.sel.join(',') !== P.saved.join(','); }
  function pkGet(id) {
    var b = P.bank || [];
    for (var i = 0; i < b.length; i++) if (b[i].id === id) return b[i];
    return null;
  }
  function pkOptions(q) {
    var o = q.options;
    if (typeof o === 'string') { try { o = JSON.parse(o); } catch (e) { o = []; } }
    return Array.isArray(o) ? o : [];
  }

  function openPicker() {
    var g = game();
    if (!g || g.status !== 'lobby') { toast('Questions can only be changed in the lobby, before the quiz starts.'); return; }
    if (cardOn()) { toast('Turn card mode off to change the questions.'); return; }
    P.open = true; P.loading = true; P.err = ''; P.msg = ''; P.armClose = 0; P.openId = null;
    $('picker').hidden = false;
    pkRender();
    call('host_bank').then(function (r) {
      P.loading = false;
      if (r.network) P.err = 'net';
      else if (r.error || !r.data || !r.data.bank) P.err = 'missing';
      else {
        P.bank = r.data.bank;
        P.sel = (r.data.selected || []).slice();
        P.saved = P.sel.slice();
        P.unlinked = r.data.unlinked || 0;
      }
      pkRender();
      if (!P.err) $('pkSearch').focus();
    });
  }

  function closePicker(force) {
    if (!P.open) return;
    if (!force && pkDirty() && !(P.armClose > Date.now())) {
      P.armClose = Date.now() + 4000;
      pkRender();
      setTimeout(pkRender, 4100);
      return;
    }
    P.open = false; P.armClose = 0;
    $('picker').hidden = true;
  }

  function pkMatches(q) {
    if (P.filter === 'Answer checked') { if (!q.verified) return false; }
    else if (P.filter === 'In this quiz') { if (P.sel.indexOf(q.id) < 0) return false; }
    else if (P.filter !== 'All' && q.module !== P.filter) return false;
    var s = P.search.trim().toLowerCase();
    if (!s) return true;
    return (q.text + ' ' + q.module + ' ' + q.category + ' ' + pkOptions(q).join(' ')).toLowerCase().indexOf(s) >= 0;
  }

  function pkRow(q) {
    var pos = P.sel.indexOf(q.id), on = pos >= 0, o = pkOptions(q);
    var kind = o.length === 2 && /^true$/i.test(o[0]) && /^false$/i.test(o[1]) ? 'True or false' : o.length + ' options';
    var tags = '<span class="tag">' + esc(q.module) + '</span>' +
      (q.category && q.module.toLowerCase().indexOf(String(q.category).toLowerCase()) < 0 ? '<span class="tag">' + esc(q.category) + '</span>' : '') +
      '<span class="tag">' + kind + '</span>' +
      (q.verified ? '<span class="tag ok">Answer checked</span>' : '<span class="tag warn">Answer not confirmed</span>');
    var more = '';
    if (P.openId === q.id) {
      more = '<ol class="pk-opts">' + o.map(function (t, i) {
        return '<li class="' + (P.answers && i === q.correct_index ? 'right' : '') + '"><i>' + Q.LETTERS[i] + '</i><span>' + esc(t) + '</span></li>';
      }).join('') + '</ol>' +
        (q.note ? '<p class="pk-note">' + esc(q.note) + '</p>' : '') +
        (P.answers && q.explanation ? '<p class="pk-expl">' + esc(q.explanation) + '</p>' : '') +
        (P.answers ? '' : '<p class="pk-expl">Tick Show answers to see the right answer.</p>');
    }
    return '<div class="pk-q' + (on ? ' on' : '') + '">' +
      '<button type="button" class="pk-add" data-pk="toggle" data-id="' + q.id + '" aria-pressed="' + on + '" aria-label="' +
      (on ? 'Remove from the quiz' : 'Add to the quiz') + '">' + (on ? pos + 1 : '+') + '</button>' +
      '<div class="pk-main" data-pk="expand" data-id="' + q.id + '" role="button" tabindex="0" aria-expanded="' + (P.openId === q.id) + '">' +
      '<p class="pk-text">' + esc(q.text) + '</p><div class="pk-meta">' + tags + '</div>' + more + '</div></div>';
  }

  function pkRender() {
    if (!P.open) return;
    var bank = P.bank || [];
    var close = $('pkClose'), armed = P.armClose > Date.now();
    close.textContent = armed ? 'Close without saving?' : 'Close';
    close.className = 'pk-btn' + (armed ? ' arm' : '');
    $('pkAnswers').checked = P.answers;

    // filters
    var mods = [];
    bank.forEach(function (q) { if (mods.indexOf(q.module) < 0) mods.push(q.module); });
    var filters = [['All', bank.length]].concat(mods.map(function (m) {
      return [m, bank.filter(function (q) { return q.module === m; }).length];
    }));
    if (bank.length) {
      filters.push(['Answer checked', bank.filter(function (q) { return q.verified; }).length]);
      filters.push(['In this quiz', P.sel.length]);
    }
    $('pkFilters').innerHTML = filters.map(function (f) {
      return '<button type="button" data-pk="filter" data-f="' + esc(f[0]) + '" aria-pressed="' + (P.filter === f[0]) + '">' +
        esc(f[0]) + '<b>' + f[1] + '</b></button>';
    }).join('');

    // bank list
    var list = $('pkList'), top = list.scrollTop, html;
    if (P.loading && !P.bank) html = '<p class="pk-empty">Loading the question bank...</p>';
    else if (P.err === 'net') html = '<p class="pk-empty">No connection. The question bank needs the internet.</p>';
    else if (P.err === 'missing') html = '<p class="pk-empty">The question bank is not set up in Supabase yet. In the SQL editor, run <code>migrations/question_bank.sql</code>, then <code>bank.local.sql</code>.</p>';
    else if (!bank.length) html = '<p class="pk-empty">The bank is empty. Run <code>bank.local.sql</code> in the Supabase SQL editor.</p>';
    else {
      var shown = bank.filter(pkMatches);
      html = shown.length ? shown.map(pkRow).join('') : '<p class="pk-empty">No questions match.</p>';
    }
    list.innerHTML = html;
    list.scrollTop = top;

    // this quiz
    var chosen = P.sel.map(pkGet).filter(Boolean);
    $('pkCount').textContent = chosen.length ? ' · ' + chosen.length : '';
    $('pkChosen').innerHTML = chosen.length ? chosen.map(function (q, i) {
      return '<li><span class="n">' + (i + 1) + '</span><span class="t">' + esc(q.text) + '</span><span class="acts">' +
        '<button type="button" data-pk="up" data-id="' + q.id + '" aria-label="Move up"' + (i === 0 ? ' disabled' : '') + '>&#8593;</button>' +
        '<button type="button" data-pk="down" data-id="' + q.id + '" aria-label="Move down"' + (i === chosen.length - 1 ? ' disabled' : '') + '>&#8595;</button>' +
        '<button type="button" data-pk="remove" data-id="' + q.id + '" aria-label="Remove">&#215;</button></span></li>';
    }).join('') : '<li class="pk-empty" style="display:block">Nothing picked yet. Press + on a question to add it.</li>';

    var msg = P.msg;
    if (!msg && chosen.length) {
      var open = chosen.filter(function (q) { return !q.verified; }).length;
      msg = chosen.length + (chosen.length === 1 ? ' question' : ' questions') + ', about ' + Math.max(1, Math.round(chosen.length * 1.1)) + ' minutes.' +
        (open ? ' ' + open + (open === 1 ? ' has' : ' have') + ' an answer that is not confirmed yet.' : '');
    }
    if (!msg && P.unlinked) msg = 'The quiz in the database has ' + P.unlinked + ' questions that are not in the bank. Saving replaces them.';
    $('pkMsg').textContent = msg || '';
    var save = $('pkSave');
    save.disabled = P.loading || !chosen.length || !pkDirty();
    save.textContent = P.loading && P.bank ? 'Saving...' : !pkDirty() && chosen.length ? 'Saved' : 'Save quiz';
  }

  function pkSave() {
    if (P.loading || !P.sel.length || !pkDirty()) return;
    P.loading = true; P.msg = '';
    pkRender();
    var ids = P.sel.slice();
    call('host_set_questions', { p_ids: ids }).then(function (r) {
      P.loading = false;
      var note = r.data && r.data.note;
      if (r.network) P.msg = 'No connection. Nothing was saved.';
      else if (note === 'questions_set') {
        P.saved = ids; P.unlinked = 0;
        loadQuestions(); // refresh the copy kept for card mode
        toast('Quiz saved: ' + ids.length + (ids.length === 1 ? ' question.' : ' questions.'));
        closePicker(true);
        render();
        return;
      }
      else if (note === 'not_in_lobby') P.msg = 'The quiz has already started. Reset the game to change the questions.';
      else if (note === 'bad_count') P.msg = 'Pick between 1 and 40 questions.';
      else if (note === 'bad_ids') P.msg = 'One of these questions is no longer in the bank. Close and open the picker again.';
      else P.msg = 'Could not save' + (r.error ? ': ' + r.error : '.');
      pkRender();
    });
  }

  $('picker').addEventListener('click', function (e) {
    var b = e.target.closest('[data-pk]');
    if (!b || b.disabled) return;
    var a = b.getAttribute('data-pk'), id = Number(b.getAttribute('data-id'));
    if (a === 'close') return closePicker();
    if (a === 'save') return pkSave();
    P.msg = ''; P.armClose = 0;
    var i = P.sel.indexOf(id);
    if (a === 'toggle') {
      if (i >= 0) P.sel.splice(i, 1);
      else if (P.sel.length >= 40) P.msg = 'A quiz can have 40 questions at most.';
      else P.sel.push(id);
    }
    else if (a === 'remove') { if (i >= 0) P.sel.splice(i, 1); }
    else if (a === 'up') { if (i > 0) { P.sel.splice(i, 1); P.sel.splice(i - 1, 0, id); } }
    else if (a === 'down') { if (i >= 0 && i < P.sel.length - 1) { P.sel.splice(i, 1); P.sel.splice(i + 1, 0, id); } }
    else if (a === 'expand') P.openId = P.openId === id ? null : id;
    else if (a === 'filter') P.filter = b.getAttribute('data-f');
    else if (a === 'clear') P.sel = [];
    else if (a === 'shuffle') {
      for (var k = P.sel.length - 1; k > 0; k--) {
        var j = Math.floor(Math.random() * (k + 1)), tmp = P.sel[k];
        P.sel[k] = P.sel[j]; P.sel[j] = tmp;
      }
    }
    pkRender();
  });
  $('picker').addEventListener('keydown', function (e) {
    var m = e.target.closest && e.target.closest('.pk-main');
    if (m && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); m.click(); }
  });
  $('pkSearch').addEventListener('input', function (e) { P.search = e.target.value; pkRender(); });
  $('pkAnswers').addEventListener('change', function (e) { P.answers = e.target.checked; pkRender(); });

  // ---------------------------------------------------------------- setup: event name and teams
  // Saved on the game row, so the big screen and every phone show the same
  // event name and the same list of teams. Lobby only.
  var S = { open: false, event: '', teams: [], saved: '', loading: false, msg: '', armClose: 0 };

  function suClean(t) { return String(t || '').replace(/\s+/g, ' ').trim(); }
  function suSnapshot() {
    return JSON.stringify([suClean(S.event), S.teams.map(suClean).filter(Boolean)]);
  }
  function suMembers() {
    var m = {};
    players().forEach(function (p) { m[p.group] = (m[p.group] || 0) + 1; });
    return m;
  }

  function openSetup() {
    var g = game();
    if (!g || g.status !== 'lobby') { toast('The event name and teams can only be changed in the lobby.'); return; }
    if (cardOn()) { toast('Turn card mode off to change the setup.'); return; }
    S.open = true; S.loading = false; S.msg = ''; S.armClose = 0;
    S.event = Q.EVENT;
    S.teams = Q.GROUPS.slice();
    S.saved = suSnapshot();
    $('setup').hidden = false;
    $('suEvent').value = S.event;
    suRenderTeams();
    suSync();
    $('suEvent').focus();
  }

  function closeSetup(force) {
    if (!S.open) return;
    if (!force && suSnapshot() !== S.saved && !(S.armClose > Date.now())) {
      S.armClose = Date.now() + 4000;
      suSync();
      setTimeout(suSync, 4100);
      return;
    }
    S.open = false; S.armClose = 0;
    $('setup').hidden = true;
  }

  // The team inputs are only rebuilt when a team is added or removed, so typing never loses focus.
  function suRenderTeams() {
    var mem = suMembers();
    $('suTeams').innerHTML = S.teams.map(function (t, i) {
      var n = mem[t] || 0;
      return '<div class="su-team"><span class="n">' + (i + 1) + '</span>' +
        '<input data-i="' + i + '" maxlength="20" autocomplete="off" spellcheck="false" aria-label="Team ' + (i + 1) + '" value="' + esc(t) + '"' +
        (n ? ' readonly title="This team already has players"' : '') + '>' +
        (n ? '<span class="tag">' + n + (n === 1 ? ' player' : ' players') + '</span>'
           : '<button type="button" data-su="remove" data-i="' + i + '" aria-label="Remove team ' + (i + 1) + '">&#215;</button>') +
        '</div>';
    }).join('');
  }

  function suSync() {
    if (!S.open) return;
    var names = S.teams.map(suClean).filter(Boolean);
    var armed = S.armClose > Date.now();
    $('suClose').textContent = armed ? 'Close without saving?' : 'Close';
    $('suClose').className = 'pk-btn' + (armed ? ' arm' : '');
    $('suCount').textContent = String(names.length);
    $('suAdd').disabled = S.teams.length >= 20;
    Array.prototype.forEach.call(document.querySelectorAll('#suTeams [data-su="remove"]'), function (b) {
      b.disabled = S.teams.length <= 2;
    });
    $('suMsg').textContent = S.msg;
    var dirty = suSnapshot() !== S.saved;
    $('suSave').disabled = S.loading || !dirty;
    $('suSave').textContent = S.loading ? 'Saving...' : dirty ? 'Save' : 'Saved';
  }

  function suSave() {
    if (S.loading) return;
    var ev = suClean(S.event), names = S.teams.map(suClean).filter(Boolean), seen = {}, dup = false;
    names.forEach(function (n) { var k = n.toLowerCase(); if (seen[k]) dup = true; seen[k] = 1; });
    S.msg = !ev ? 'Give the event a name.'
      : names.length < 2 ? 'Add at least two teams.'
      : names.length > 20 ? 'Twenty teams is the most.'
      : dup ? 'Two teams have the same name.' : '';
    if (S.msg) return suSync();
    S.loading = true;
    suSync();
    call('host_set_setup', { p_event: ev, p_teams: names }).then(function (r) {
      S.loading = false;
      var note = r.data && r.data.note;
      if (r.network) S.msg = 'No connection. Nothing was saved.';
      else if (note === 'setup_saved') {
        toast('Saved. ' + names.length + ' teams.');
        closeSetup(true);
        H.seen = null;
        render();
        return;
      }
      else if (note === 'team_in_use') S.msg = 'A team with players in it cannot be removed or renamed. Remove those players first (Players button), or reset the game.';
      else if (note === 'bad_teams') S.msg = 'Team names must all be different, 20 characters or fewer, with no < > or " in them.';
      else if (note === 'bad_team_count') S.msg = 'Use between 2 and 20 teams.';
      else if (note === 'bad_event') S.msg = 'The event name must be 1 to 40 characters.';
      else if (note === 'not_in_lobby') S.msg = 'The quiz has already started. Reset the game to change the setup.';
      else if (r.error && /find the function|does not exist/i.test(r.error)) S.msg = 'Setup is not switched on in Supabase yet. Run migrations/editable_setup.sql in the SQL editor.';
      else S.msg = 'Could not save' + (r.error ? ': ' + r.error : '.');
      suSync();
    });
  }

  $('setup').addEventListener('click', function (e) {
    var b = e.target.closest('[data-su]');
    if (!b || b.disabled) return;
    var a = b.getAttribute('data-su');
    if (a === 'close') return closeSetup();
    if (a === 'save') return suSave();
    S.msg = ''; S.armClose = 0;
    if (a === 'add' && S.teams.length < 20) {
      S.teams.push('');
      suRenderTeams();
      var inputs = document.querySelectorAll('#suTeams input');
      if (inputs.length) inputs[inputs.length - 1].focus();
    } else if (a === 'remove' && S.teams.length > 2) {
      S.teams.splice(Number(b.getAttribute('data-i')), 1);
      suRenderTeams();
    }
    suSync();
  });
  $('setup').addEventListener('input', function (e) {
    var t = e.target;
    if (t.id === 'suEvent') S.event = t.value;
    else if (t.hasAttribute('data-i')) S.teams[Number(t.getAttribute('data-i'))] = t.value;
    S.msg = ''; S.armClose = 0;
    suSync();
  });
  $('setup').addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && e.target.tagName === 'INPUT') { e.preventDefault(); suSave(); }
  });

  // ---------------------------------------------------------------- PIN gate
  function sha(text) {
    try {
      return crypto.subtle.digest('SHA-256', new TextEncoder().encode(CODE + ':' + text)).then(function (buf) {
        return Array.prototype.map.call(new Uint8Array(buf), function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
      });
    } catch (e) { return Promise.resolve(null); }
  }

  function relock(reason) {
    H.unlocked = false;
    H.pin = null;
    Q.session.del(K.pin);
    $('gate').hidden = false;
    $('gateError').textContent = reason === 'pin_not_set'
      ? 'No host PIN is set yet. Run set_host_pin in the Supabase SQL editor.'
      : 'Wrong PIN. Try again.';
    $('pin').focus();
  }

  function unlocked() {
    H.unlocked = true;
    H.seen = null; // the cached lobby may be old: do not greet everyone at once
    $('pin').blur();
    $('gate').hidden = true;
    render();
  }

  function tryUnlock(pin) {
    var btn = $('gateBtn'), err = $('gateError');
    err.textContent = '';
    if (!Q.configured) {
      err.textContent = 'Add the Supabase URL and anon key to config.js first.';
      offlineOption(pin);
      return;
    }
    btn.disabled = true; btn.textContent = 'Checking...';
    H.pin = pin;
    var sent = Date.now();
    Q.rpc('host_login', { p_code: CODE, p_pin: pin }, 10000).then(function (r) {
      btn.disabled = false; btn.textContent = 'Unlock';
      if (r.network) {
        setOnline(false);
        err.textContent = 'No connection to Supabase.';
        offlineOption(pin);
        return;
      }
      if (r.error) {
        H.pin = null; Q.session.del(K.pin);
        err.textContent = {
          bad_pin: 'Wrong PIN. Try again.',
          locked: 'Too many wrong PINs. Wait a minute and try again.',
          pin_not_set: 'No host PIN is set yet. Run set_host_pin in the Supabase SQL editor.',
          game_not_found: 'No game called ' + CODE + '. Run supabase.sql first.'
        }[r.error] || ('Error: ' + r.error);
        return;
      }
      setOnline(true);
      Q.session.set(K.pin, pin);
      sha(pin).then(function (h) { if (h) Q.local.set(K.pinHash, h); });
      Q.syncClock(r.data.server_now, sent, Date.now());
      // A reset elsewhere wipes local card state that no longer matches.
      if (H.view && H.view.game && r.data.game.id !== H.view.game.id) { H.card = null; Q.local.del(K.card); }
      H.view = null;
      applyView(r.data);
      loadQuestions();
      if (cardOn()) push();
      unlocked();
      if (!r.data.game.total_questions) toast('No questions loaded. Run questions.local.sql in Supabase.');
    });
  }

  // Offline start: only with cached questions and the PIN that last worked here.
  function offlineOption(pin) {
    var b = $('offlineBtn');
    if (!H.questions) { b.hidden = true; return; }
    sha(pin).then(function (h) {
      var known = Q.local.get(K.pinHash);
      var match = !!(h && known && h === known);
      b.hidden = !match;
      if (match && cardOn()) startOffline(); // reload during a card round: carry on
    });
  }

  function startOffline() {
    H.pin = $('pin').value || H.pin;
    Q.session.set(K.pin, H.pin);
    if (!cardOn()) setCardMode(true);
    unlocked();
    toast('Offline. Card mode is on. Scores sync when the internet is back.');
  }

  // ---------------------------------------------------------------- wiring
  $('controls').addEventListener('click', function (e) {
    var b = e.target.closest('button[data-act]');
    if (!b || !H.unlocked) return;
    b.blur();
    var a = b.getAttribute('data-act');
    if (a === 'next') next();
    else if (a === 'back') back();
    else if (a === 'pause') pause();
    else if (a === 'end') end();
    else if (a === 'reset') reset();
    else if (a === 'manage') { H.manage = !H.manage; render(); }
    else if (a === 'questions') openPicker();
    else if (a === 'setup') openSetup();
    else if (a === 'sound') {
      sfx.set(!sfx.on());
      if (sfx.on()) sfx.join();
      toast(sfx.on() ? 'Sound on.' : 'Sound off.');
      renderControls();
    }
    else if (a === 'voice') {
      voice.set(!voice.on());
      if (voice.on()) voice.say('Voice on.', true);
      toast(voice.on() ? 'Voice on. The page reads questions and results aloud.' : 'Voice off.');
      renderControls();
    }
    else if (a === 'scores') {
      H.hideScores = !H.hideScores;
      Q.local.set(K.hideScores, H.hideScores ? 'on' : 'off');
      toast(H.hideScores ? 'Team scores hidden until the final results.' : 'Team scores shown.');
      renderControls();
      render();
    }
    else if (a === 'fullscreen') {
      try {
        if (document.fullscreenElement) document.exitFullscreen();
        else document.documentElement.requestFullscreen();
      } catch (err) {}
    }
  });
  $('cardToggle').addEventListener('change', function (e) {
    e.target.blur();
    if (!H.unlocked) { e.target.checked = cardOn(); return; }
    var want = e.target.checked; // read first: armed() redraws the controls and resets the box
    // Turning card mode ON stops every phone from answering, so it takes two clicks
    // (like End quiz). Turning it off is one click.
    if (want && !cardOn() &&
        !armed('card', 'Click Card mode again to turn phone answers off. Teams then hold up cards.')) {
      e.target.checked = false;
      return;
    }
    setCardMode(want);
  });
  // Space is the host's Next key: never let it flip the checkbox if it has focus.
  $('cardToggle').addEventListener('keyup', function (e) { if (e.key === ' ') e.preventDefault(); });
  $('cardToggle').addEventListener('keydown', function (e) { if (e.key === ' ') e.preventDefault(); });
  stage.addEventListener('click', function (e) {
    var aw = e.target.closest('[data-award]');
    if (aw) return toggleAward(aw.getAttribute('data-award'));
    var rm = e.target.closest('[data-remove]');
    if (rm) return removePlayer(rm.getAttribute('data-remove'), rm.getAttribute('data-name'));
  });
  // Browsers only allow sound after a click or key press.
  document.addEventListener('pointerdown', function () { sfx.unlock(); }, true);
  document.addEventListener('keydown', function () { sfx.unlock(); }, true);
  document.addEventListener('keydown', function (e) {
    if (P.open) { if (e.key === 'Escape') closePicker(); return; }
    if (S.open) { if (e.key === 'Escape') closeSetup(); return; }
    if (!H.unlocked || e.repeat || e.ctrlKey || e.metaKey || e.altKey) return;
    var t = e.target;
    if (t && ((t.tagName === 'INPUT' && t.type !== 'checkbox') || t.tagName === 'TEXTAREA')) return;
    if (e.key === ' ' || e.key === 'Enter' || e.key === 'ArrowRight' || e.key === 'PageDown') { e.preventDefault(); next(); }
    else if (e.key === 'ArrowLeft' || e.key === 'PageUp') { e.preventDefault(); back(); }
  });
  $('gateForm').addEventListener('submit', function (e) {
    e.preventDefault();
    var pin = $('pin').value.trim();
    if (pin) tryUnlock(pin);
  });
  $('offlineBtn').addEventListener('click', startOffline);
  window.addEventListener('online', function () { if (H.unlocked) call('host_state').then(render); });

  setInterval(tick, 100);
  render();
  if (H.pin) { $('pin').value = H.pin; tryUnlock(H.pin); } else { $('pin').focus(); }
  setTimeout(poll, 1000);

  // Keep the host page available offline for card mode after a reload.
  if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost' || location.hostname === '127.0.0.1')) {
    navigator.serviceWorker.register('sw.js').catch(function () {});
  }
})();

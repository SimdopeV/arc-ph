-- Batch 3: new question types (poll, type answer, slider, puzzle).
-- Run once in the Supabase SQL editor on a database set up before this change.
-- Safe to run again. Players, answers, the quiz and the question bank are kept:
-- every existing question stays an ordinary quiz question ("choice").
--
-- Scoring (agreed with the host):
--   poll    no right answer, no points
--   type    right when it matches an accepted answer, ignoring case and spaces
--   slider  inside the margin: full points for the exact number, down to half at the edge; outside: 0
--   puzzle  all or nothing: every item in its place
-- Speed and the double/no points setting work as for every other question.

alter table public.games add column if not exists kind text not null default 'choice';
alter table public.games add column if not exists spec jsonb;
alter table public.games add column if not exists answer jsonb;

alter table public.questions add column if not exists kind text not null default 'choice'
  check (kind in ('choice', 'poll', 'type', 'slider', 'puzzle'));
alter table public.questions add column if not exists spec jsonb;
alter table public.question_bank add column if not exists kind text not null default 'choice'
  check (kind in ('choice', 'poll', 'type', 'slider', 'puzzle'));
alter table public.question_bank add column if not exists spec jsonb;

alter table public.answers alter column choice drop not null;
alter table public.answers add column if not exists response jsonb;

do $$
declare t text;
begin
  foreach t in array array['questions', 'question_bank'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_options_n');
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_correct_ok');
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_spec_ok');
    execute format($f$alter table public.%I add constraint %I check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between
      case kind when 'type' then 1 when 'slider' then 0 when 'puzzle' then 3 else 2 end and
      case kind when 'type' then 4 when 'slider' then 0 when 'puzzle' then 4 else 6 end)$f$, t, t || '_options_n');
    execute format($f$alter table public.%I add constraint %I check (correct_index between 0 and 5 and (kind <> 'choice' or correct_index < jsonb_array_length(options)))$f$,
      t, t || '_correct_ok');
    execute format($f$alter table public.%I add constraint %I check (kind <> 'slider' or (jsonb_typeof(spec->'min') = 'number' and jsonb_typeof(spec->'max') = 'number'
      and jsonb_typeof(spec->'step') = 'number' and jsonb_typeof(spec->'answer') = 'number' and jsonb_typeof(spec->'margin') = 'number'))$f$,
      t, t || '_spec_ok');
  end loop;
end $$;

-- Keeps correct_index and correct_set in step, and checks the set:
-- single answer: the set is just correct_index; multi-select: sorted, no repeats,
-- at least one, each one an answer that exists. Other question types: an empty set.
create or replace function public._fix_correct()
returns trigger language plpgsql as $$
declare n int := jsonb_array_length(new.options);
begin
  -- Polls have no right answer; type, slider and puzzle keep theirs in options and spec.
  if new.kind <> 'choice' then
    new.multi := false; new.correct_index := 0; new.correct_set := '{}';
    return new;
  end if;
  if not new.multi or new.correct_set is null or cardinality(new.correct_set) = 0 then
    new.correct_set := array[new.correct_index];
  else
    select array_agg(distinct x order by x) into new.correct_set from unnest(new.correct_set) x;
    if exists (select 1 from unnest(new.correct_set) x where x is null or x < 0 or x >= n) then
      raise exception 'correct_set has an answer that does not exist';
    end if;
    new.correct_index := new.correct_set[1];
  end if;
  return new;
end $$;

-- Type answer matching: case and spaces do not count.
create or replace function public._norm(p text)
returns text language sql immutable as $$
  select lower(regexp_replace(coalesce(p, ''), '\s+', '', 'g'))
$$;

create or replace function public._public_game(g public.games)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', g.id, 'join_code', g.join_code, 'status', g.status,
    'current_index', g.current_index, 'total_questions', g.total_questions,
    'duration_s', g.duration_s, 'category', g.category,
    'question_text', g.question_text, 'options', g.options,
    'started_at', g.started_at, 'paused_at', g.paused_at,
    'revealed_index', g.revealed_index, 'revealed_set', g.revealed_set, 'multi', g.multi,
    'kind', g.kind, 'spec', g.spec, 'answer', g.answer,
    'explanation', g.explanation,
    'card_mode', g.card_mode, 'points', g.points, 'event_name', g.event_name, 'teams', g.teams,
    'updated_at', g.updated_at)
$$;

-- Moves the game to a status and question, loading the question fields from
-- questions. The correct index is copied only for reveal, leaderboard, final.
create or replace function public._apply(p_game uuid, p_status text, p_index int)
returns void language plpgsql security definer set search_path = public as $$
declare
  q public.questions;
  g public.games;
  shown boolean := p_status in ('reveal', 'leaderboard', 'final');
  v_opts jsonb;
  v_order jsonb;
  tries int := 0;
begin
  select * into g from public.games where id = p_game for update;
  if p_status = 'lobby' or p_index < 0 then
    update public.games set status = 'lobby', current_index = -1, category = null,
           question_text = null, options = null, started_at = null, paused_at = null,
           revealed_index = null, revealed_set = null, multi = false, kind = 'choice', spec = null, answer = null,
           explanation = null, updated_at = now()
     where id = p_game;
    return;
  end if;

  select * into q from public.questions where game_id = p_game and idx = p_index;
  if q.idx is null then raise exception 'question % not found', p_index; end if;

  -- What the phones may see. Type and slider answers never go in the games row
  -- before the reveal. Puzzle items are shuffled once per question and keep that order.
  v_opts := case q.kind when 'type' then '[]'::jsonb when 'slider' then '[]'::jsonb else q.options end;
  if q.kind = 'puzzle' then
    if g.kind = 'puzzle' and g.current_index = p_index and g.status <> 'lobby' and g.options is not null
       and g.options @> q.options and q.options @> g.options then
      v_opts := g.options;
    else
      loop
        select jsonb_agg(x order by random()) into v_opts from jsonb_array_elements(q.options) x;
        tries := tries + 1;
        exit when v_opts <> q.options or tries >= 20;
      end loop;
    end if;
    -- The right order, as positions in the shuffled list.
    select jsonb_agg((select (s.o - 1)::int from jsonb_array_elements(v_opts) with ordinality s(x, o) where s.x = t.x limit 1) order by t.o)
      into v_order from jsonb_array_elements(q.options) with ordinality t(x, o);
  end if;

  update public.games set
    status         = p_status,
    current_index  = p_index,
    category       = q.category,
    question_text  = q.text,
    options        = v_opts,
    duration_s     = q.time_s,
    points         = q.points,
    multi          = q.multi,
    kind           = q.kind,
    spec           = case when q.kind = 'slider' then jsonb_build_object('min', q.spec->'min', 'max', q.spec->'max',
                       'step', q.spec->'step', 'unit', coalesce(q.spec->'unit', '""'::jsonb)) end,
    started_at     = case
                       when p_status = 'question' and (g.status <> 'question' or g.current_index <> p_index) then now()
                       when p_status = 'question' then g.started_at
                       else coalesce(case when g.current_index = p_index then g.started_at end, now())
                     end,
    paused_at      = case when p_status = 'question' and g.status = 'question' and g.current_index = p_index
                          then g.paused_at end,
    revealed_index = case when shown and q.kind = 'choice' then q.correct_index end,
    revealed_set   = case when shown then case when q.kind = 'choice' then q.correct_set else '{}'::int[] end end,
    answer         = case when shown then case q.kind
                       when 'type' then jsonb_build_object('accept', q.options)
                       when 'slider' then jsonb_build_object('answer', q.spec->'answer', 'margin', q.spec->'margin')
                       when 'puzzle' then jsonb_build_object('order', v_order)
                     end end,
    explanation    = case when shown then q.explanation end,
    updated_at     = now()
  where id = p_game;
end $$;

-- Full host view: game row, players (with points gained on the current question), groups,
-- answer count (in total and per team), distribution.
create or replace function public._host_view(p_game uuid, p_note text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  g public.games;
  dist jsonb := null;
  n_in int := 0;
  by_team jsonb := '{}'::jsonb;
  n_right int := 0;
  resp jsonb := null;
  v_min numeric; v_max numeric;
begin
  select * into g from public.games where id = p_game;
  if g.current_index >= 0 then
    select count(*) into n_in from public.answers
     where game_id = p_game and question_idx = g.current_index;
    select coalesce(jsonb_object_agg(t.group_name, t.n), '{}'::jsonb) into by_team
      from (select p.group_name, count(*)::int n
              from public.answers a join public.players p on p.id = a.player_id
             where a.game_id = p_game and a.question_idx = g.current_index
             group by p.group_name) t;
    if g.status in ('reveal', 'leaderboard', 'final') and g.kind in ('choice', 'poll') then
      -- Votes per answer; a multi-select answer counts once for each answer ticked.
      select jsonb_agg(coalesce(c.n, 0) order by s.i) into dist
        from generate_series(0, coalesce(jsonb_array_length(g.options), 4) - 1) s(i)
        left join (select x as choice, count(*)::int n
                     from public.answers a, unnest(coalesce(a.choices, array[a.choice])) x
                    where a.game_id = p_game and a.question_idx = g.current_index
                    group by x) c on c.choice = s.i;
    end if;
    if g.status in ('reveal', 'leaderboard', 'final') then
      select count(*) into n_right from public.answers
       where game_id = p_game and question_idx = g.current_index and is_correct;
    end if;
    if g.status in ('reveal', 'leaderboard', 'final') and g.kind = 'type' then
      -- The most common answers typed (case and spaces ignored). Rude ones are left out: this goes on the big screen.
      select jsonb_build_object('top', coalesce(jsonb_agg(jsonb_build_object('text', t.txt, 'n', t.n, 'right', t.ok)
               order by t.n desc, t.txt), '[]'::jsonb)) into resp
        from (select min(a.response #>> '{}') txt, count(*)::int n, bool_or(a.is_correct) ok
                from public.answers a
               where a.game_id = p_game and a.question_idx = g.current_index and a.response is not null
                 and not public._name_is_blocked(a.response #>> '{}')
               group by public._norm(a.response #>> '{}')
               order by count(*) desc, min(a.response #>> '{}') limit 8) t;
    elsif g.status in ('reveal', 'leaderboard', 'final') and g.kind = 'slider' then
      -- Guesses in 20 equal buckets from min to max, and the average guess.
      v_min := (g.spec->>'min')::numeric; v_max := (g.spec->>'max')::numeric;
      select jsonb_build_object(
               'buckets', (select jsonb_agg(coalesce(c.n, 0) order by b.i)
                             from generate_series(0, 19) b(i)
                             left join (select least(19, greatest(0, floor(((a.response #>> '{}')::numeric - v_min) / nullif(v_max - v_min, 0) * 20)))::int k,
                                               count(*)::int n
                                          from public.answers a
                                         where a.game_id = p_game and a.question_idx = g.current_index and jsonb_typeof(a.response) = 'number'
                                         group by 1) c on c.k = b.i),
               'avg', (select round(avg((a.response #>> '{}')::numeric), 2) from public.answers a
                        where a.game_id = p_game and a.question_idx = g.current_index and jsonb_typeof(a.response) = 'number'))
        into resp;
    end if;
  end if;

  return jsonb_build_object(
    'game', public._public_game(g),
    'server_now', now(),
    'answers_in', n_in,
    'right_in', n_right,
    'team_answers', by_team,
    'distribution', dist,
    'responses', resp,
    'note', p_note,
    'players', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.player_id, 'name', t.name, 'label', t.label, 'group', t.group_name,
        'total', t.total, 'correct', t.correct, 'answered', t.answered, 'rank', t.rank,
        'gained', coalesce(cur.points, 0))
        order by t.total desc, t.correct desc, t.joined_at)
      from public._player_totals(p_game) t
      left join public.answers cur on cur.player_id = t.player_id and cur.question_idx = g.current_index), '[]'::jsonb),
    'groups', (select jsonb_agg(jsonb_build_object(
        'name', s.group_name, 'members', s.members, 'avg', s.avg_total,
        'card_points', s.card_points, 'score', s.score, 'correct', s.correct, 'rank', s.rank))
      from public._group_scores(p_game) s),
    'card_awards', coalesce((select jsonb_object_agg(x.question_idx, x.groups) from (
        select question_idx, jsonb_agg(group_name order by group_name) groups
        from public.card_awards where game_id = p_game group by question_idx) x), '{}'::jsonb)
  );
end $$;

-- One call to catch up: player, game row, server time, this question's answer
-- state, and (only once revealed) this question's result and the rankings.
create or replace function public.player_sync(p_player uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.players;
  g public.games;
  a public.answers;
  me record;
  grp record;
  n_players int;
  res jsonb := null;
  fin jsonb := null;
begin
  select * into p from public.players where id = p_player;
  if p.id is null then
    return jsonb_build_object('player', null, 'server_now', now());
  end if;
  select * into g from public.games where id = p.game_id;

  if g.current_index >= 0 then
    select * into a from public.answers where player_id = p.id and question_idx = g.current_index;
  end if;

  select * into me from public._player_totals(g.id) t where t.player_id = p.id;

  if g.status in ('reveal', 'leaderboard', 'final') and g.current_index >= 0 then
    select count(*) into n_players from public.players where game_id = g.id;
    res := jsonb_build_object(
      'question_idx', g.current_index,
      'answered', a.id is not null,
      'choice', a.choice,
      'choices', a.choices,
      'response', a.response,
      'kind', g.kind,
      'is_correct', coalesce(a.is_correct, false),
      'points', coalesce(a.points, 0),
      'rank', me.rank, 'players', n_players);
  end if;

  if g.status = 'final' then
    select count(*) into n_players from public.players where game_id = g.id;
    select * into grp from public._group_scores(g.id) s where s.group_name = p.group_name;
    fin := jsonb_build_object(
      'rank', me.rank, 'players', n_players,
      'group_rank', grp.rank, 'groups', array_length(public._groups(g.id), 1),
      'group_score', round(grp.score));
  end if;

  return jsonb_build_object(
    'player', jsonb_build_object('id', p.id, 'name', p.name, 'group', p.group_name),
    'game', public._public_game(g),
    'server_now', now(),
    'answered', a.id is not null,
    'choice', a.choice,
    'choices', a.choices,
    'response', a.response,
    'total', me.total,
    'result', res,
    'final', fin);
end $$;

-- Scores an answer with server time. The client never sees the right answer.
-- p_value: choice and poll: [answer numbers]; type: "text"; slider: a number;
-- puzzle: [positions in the shown list, in the order the player put them].
create or replace function public.submit_response(p_player uuid, p_question_idx int, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p public.players;
  g public.games;
  q public.questions;
  v_set int[];
  v_n int;
  v_right int;
  v_wrong int;
  v_elapsed numeric;
  v_correct boolean := false;
  v_points int := 0;
  v_base int;
  v_mult int;
  v_resp jsonb := null;
  v_text text;
  v_num numeric; v_min numeric; v_max numeric; v_ans numeric; v_margin numeric; v_d numeric;
  v_order int[];
begin
  select * into p from public.players where id = p_player;
  if p.id is null then return jsonb_build_object('error', 'player_not_found'); end if;
  select * into g from public.games where id = p.game_id;

  if g.card_mode then return jsonb_build_object('error', 'card_mode'); end if;
  if g.status <> 'question' or g.current_index <> p_question_idx then
    return jsonb_build_object('error', 'not_open');
  end if;

  -- Time stands still while the host has paused the timer.
  v_elapsed := extract(epoch from (coalesce(g.paused_at, now()) - g.started_at));
  if v_elapsed > g.duration_s + 1 then
    return jsonb_build_object('error', 'too_late');
  end if;
  v_elapsed := least(greatest(v_elapsed, 0), g.duration_s);

  select * into q from public.questions where game_id = g.id and idx = g.current_index;
  -- 500 to 1000 for a right answer (faster scores more), doubled or zeroed by the question's points setting.
  v_base := 500 + round(500 * (1 - v_elapsed / g.duration_s));
  v_mult := case q.points when 'double' then 2 when 'none' then 0 else 1 end;

  if q.kind in ('choice', 'poll') then
    if jsonb_typeof(p_value) is distinct from 'array'
       or exists (select 1 from jsonb_array_elements(p_value) x where jsonb_typeof(x) not in ('number', 'null')
                     or (jsonb_typeof(x) = 'number' and (x #>> '{}') !~ '^\d$')) then
      return jsonb_build_object('error', 'bad_choice');
    end if;
    select array_agg(distinct (x #>> '{}')::int order by (x #>> '{}')::int) into v_set
      from jsonb_array_elements(p_value) x where jsonb_typeof(x) = 'number';
    v_n := jsonb_array_length(q.options);
    if v_set is null or v_set[cardinality(v_set)] >= v_n or (not q.multi and cardinality(v_set) <> 1) then
      return jsonb_build_object('error', 'bad_choice');
    end if;
    if q.kind = 'choice' then
      -- Right = exactly the right answers. Multi-select gives partial credit: a share of
      -- the points for each right answer ticked, but nothing if any wrong answer is ticked.
      select count(*) filter (where x = any (q.correct_set)), count(*) filter (where not (x = any (q.correct_set)))
        into v_right, v_wrong from unnest(v_set) x;
      v_correct := v_wrong = 0 and v_right = cardinality(q.correct_set);
      v_points := case when v_wrong = 0 and v_right > 0
                       then round(v_base * v_right::numeric / cardinality(q.correct_set))::int * v_mult
                       else 0 end;
    end if;
    -- A poll has no right answer and scores nothing.

  elsif q.kind = 'type' then
    if jsonb_typeof(p_value) is distinct from 'string' then return jsonb_build_object('error', 'bad_answer'); end if;
    v_text := regexp_replace(trim(p_value #>> '{}'), '\s+', ' ', 'g');
    if char_length(v_text) < 1 or char_length(v_text) > 40 then return jsonb_build_object('error', 'bad_answer'); end if;
    v_resp := to_jsonb(v_text);
    -- Right when it matches an accepted answer, ignoring case and spaces.
    v_correct := exists (select 1 from jsonb_array_elements_text(q.options) x where public._norm(x) = public._norm(v_text));
    v_points := case when v_correct then v_base * v_mult else 0 end;

  elsif q.kind = 'slider' then
    if jsonb_typeof(p_value) is distinct from 'number' then return jsonb_build_object('error', 'bad_answer'); end if;
    v_min := (q.spec->>'min')::numeric; v_max := (q.spec->>'max')::numeric;
    v_ans := (q.spec->>'answer')::numeric; v_margin := (q.spec->>'margin')::numeric;
    v_num := least(greatest((p_value #>> '{}')::numeric, v_min), v_max);
    v_resp := to_jsonb(v_num);
    -- Inside the margin: full points for the exact number, shrinking to half at the edge
    -- of the margin. Outside it: nothing.
    v_d := abs(v_num - v_ans);
    v_correct := v_d <= v_margin;
    v_points := case when not v_correct then 0
                     when v_margin = 0 then v_base * v_mult
                     else round(v_base * (1 - 0.5 * v_d / v_margin))::int * v_mult end;

  elsif q.kind = 'puzzle' then
    v_n := jsonb_array_length(g.options);
    if jsonb_typeof(p_value) is distinct from 'array' or jsonb_array_length(p_value) <> v_n
       or exists (select 1 from jsonb_array_elements(p_value) x where jsonb_typeof(x) <> 'number' or (x #>> '{}') !~ '^\d$') then
      return jsonb_build_object('error', 'bad_answer');
    end if;
    select array_agg((x #>> '{}')::int order by o) into v_order from jsonb_array_elements(p_value) with ordinality t(x, o);
    if (select count(distinct x) from unnest(v_order) x where x < v_n) <> v_n then
      return jsonb_build_object('error', 'bad_answer');
    end if;
    v_resp := to_jsonb(v_order);
    -- All or nothing: every item in its place.
    v_correct := not exists (select 1 from unnest(v_order) with ordinality t(x, o)
                              where (g.options ->> x) is distinct from (q.options ->> (o::int - 1)));
    v_points := case when v_correct then v_base * v_mult else 0 end;
  else
    return jsonb_build_object('error', 'bad_answer');
  end if;

  insert into public.answers (game_id, player_id, question_idx, choice, choices, response, elapsed_ms, is_correct, points)
  values (g.id, p.id, g.current_index, v_set[1], v_set, v_resp, round(v_elapsed * 1000)::int, v_correct, v_points)
  on conflict (player_id, question_idx) do nothing;

  if not found then return jsonb_build_object('error', 'duplicate'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Ticked answers (choice and poll questions).
create or replace function public.submit_answers(p_player uuid, p_question_idx int, p_choices int[])
returns jsonb language sql security definer set search_path = public as $$
  select public.submit_response(p_player, p_question_idx, coalesce(to_jsonb(p_choices), 'null'::jsonb))
$$;

-- Full question list with answers, for the host's offline card mode cache.
create or replace function public.host_questions(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  return jsonb_build_object('questions', (
    select jsonb_agg(jsonb_build_object(
      'idx', q.idx, 'category', q.category, 'text', q.text, 'options', q.options,
      'correct_index', q.correct_index, 'correct_set', q.correct_set, 'multi', q.multi,
      'kind', q.kind, 'spec', q.spec,
      'explanation', q.explanation, 'time_s', q.time_s, 'points', q.points) order by q.idx)
    from public.questions q where q.game_id = a.p_game));
end $$;

-- The question bank, with answers, and which bank questions are in the quiz now.
create or replace function public.host_bank(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  return jsonb_build_object(
    'bank', coalesce((select jsonb_agg(jsonb_build_object(
        'id', b.id, 'module', b.module, 'category', b.category, 'text', b.text,
        'options', b.options, 'correct_index', b.correct_index, 'correct_set', b.correct_set, 'multi', b.multi,
        'kind', b.kind, 'spec', b.spec,
        'explanation', b.explanation, 'verified', b.verified, 'note', b.note,
        'time_s', b.time_s, 'points', b.points) order by b.id)
      from public.question_bank b where b.game_id = a.p_game), '[]'::jsonb),
    'selected', coalesce((select jsonb_agg(q.bank_id order by q.idx)
      from public.questions q where q.game_id = a.p_game and q.bank_id is not null), '[]'::jsonb),
    'unlinked', (select count(*) from public.questions q where q.game_id = a.p_game and q.bank_id is null),
    'status', (select status from public.games where id = a.p_game));
end $$;

-- Replace the quiz's questions with the chosen bank questions, in the given order.
-- Only in the lobby: changing questions mid-game would break the scores.
create or replace function public.host_set_questions(p_code text, p_pin text, p_ids int[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games; n int;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.status <> 'lobby' then return public._host_view(a.p_game, 'not_in_lobby'); end if;
  n := coalesce(array_length(p_ids, 1), 0);
  if n < 1 or n > 40 then return public._host_view(a.p_game, 'bad_count'); end if;
  if (select count(distinct x) from unnest(p_ids) x) <> n
     or (select count(*) from public.question_bank b where b.game_id = a.p_game and b.id = any (p_ids)) <> n then
    return public._host_view(a.p_game, 'bad_ids');
  end if;
  -- The lobby has no scores worth keeping; old answers would point at the wrong questions.
  delete from public.card_awards where game_id = a.p_game;
  delete from public.answers where game_id = a.p_game;
  delete from public.questions where game_id = a.p_game;
  insert into public.questions (game_id, idx, category, text, options, correct_index, correct_set, multi,
                                kind, spec, explanation, time_s, points, bank_id)
  select a.p_game, (t.ord - 1)::int, b.category, b.text, b.options, b.correct_index, b.correct_set, b.multi,
         b.kind, b.spec, b.explanation, b.time_s, b.points, b.id
    from unnest(p_ids) with ordinality t(id, ord)
    join public.question_bank b on b.game_id = a.p_game and b.id = t.id;
  update public.games set total_questions = n, updated_at = now() where id = a.p_game;
  return public._host_view(a.p_game, 'questions_set');
end $$;

-- Question editor on the host page: add or change one bank question.
-- p_q: { id (null for a new one), kind (choice, poll, type, slider, puzzle), module, category, text,
--        options: choice and poll 2-6 answers, type 1-4 accepted answers, puzzle 3-4 items in the right order,
--        correct_index, correct: [right answers, for multi], multi,
--        slider: {min, max, step, answer, margin, unit} (slider only),
--        explanation, note, verified, time_s, points }
-- If the game is in the lobby and the question is in the quiz, the quiz copy is updated too.
create or replace function public.host_bank_save(p_code text, p_pin text, p_q jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record; g public.games; b public.question_bank;
  v_id int; v_text text; v_module text; v_cat text; v_expl text; v_note text;
  v_opts jsonb; v_n int; v_correct int; v_time int; v_points text; v_verified boolean;
  v_multi boolean; v_set int[];
  v_kind text; v_spec jsonb := null; v_sl jsonb;
  v_min numeric; v_max numeric; v_step numeric; v_ans numeric; v_margin numeric; v_unit text;
  v_lo int; v_hi int; v_len int;
  v_in_quiz int := 0;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;  -- one save at a time
  if p_q is null or jsonb_typeof(p_q) <> 'object' then return jsonb_build_object('note', 'bad_question'); end if;

  v_id      := case when p_q->>'id' ~ '^\d{1,6}$' then (p_q->>'id')::int end;
  v_kind    := coalesce(p_q->>'kind', 'choice');
  v_text    := regexp_replace(trim(coalesce(p_q->>'text', '')), '\s+', ' ', 'g');
  v_module  := regexp_replace(trim(coalesce(p_q->>'module', '')), '\s+', ' ', 'g');
  v_cat     := regexp_replace(trim(coalesce(nullif(trim(p_q->>'category'), ''), v_module)), '\s+', ' ', 'g');
  v_expl    := trim(coalesce(p_q->>'explanation', ''));
  v_note    := trim(coalesce(p_q->>'note', ''));
  v_correct := case when p_q->>'correct_index' ~ '^\d$' then (p_q->>'correct_index')::int end;
  v_time    := case when p_q->>'time_s' ~ '^\d{1,3}$' then (p_q->>'time_s')::int end;
  v_points  := coalesce(p_q->>'points', 'standard');
  v_verified := coalesce(p_q->>'verified', 'false') = 'true';
  v_multi   := v_kind = 'choice' and coalesce(p_q->>'multi', 'false') = 'true';

  if v_kind not in ('choice', 'poll', 'type', 'slider', 'puzzle') then return jsonb_build_object('note', 'bad_kind'); end if;
  if char_length(v_text) < 1 or char_length(v_text) > 200 then return jsonb_build_object('note', 'bad_text'); end if;
  if char_length(v_module) < 1 or char_length(v_module) > 40 then return jsonb_build_object('note', 'bad_module'); end if;
  if char_length(v_cat) > 30 then return jsonb_build_object('note', 'bad_category'); end if;
  if char_length(v_expl) > 400 or char_length(v_note) > 300 then return jsonb_build_object('note', 'bad_explanation'); end if;
  if v_time is null or v_time not in (5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240) then return jsonb_build_object('note', 'bad_time'); end if;
  if v_points not in ('standard', 'double', 'none') then return jsonb_build_object('note', 'bad_points'); end if;

  if v_kind = 'slider' then
    -- {min, max, step, answer, margin, unit}: the answer and both ends sit on the step.
    v_sl := p_q->'slider';
    if jsonb_typeof(v_sl) is distinct from 'object'
       or exists (select 1 from unnest(array['min', 'max', 'step', 'answer', 'margin']) k
                   where jsonb_typeof(v_sl->k) is distinct from 'number' or abs((v_sl->>k)::numeric) > 1000000000) then
      return jsonb_build_object('note', 'bad_slider');
    end if;
    v_min := (v_sl->>'min')::numeric; v_max := (v_sl->>'max')::numeric; v_step := (v_sl->>'step')::numeric;
    v_ans := (v_sl->>'answer')::numeric; v_margin := (v_sl->>'margin')::numeric;
    v_unit := regexp_replace(trim(coalesce(v_sl->>'unit', '')), '\s+', ' ', 'g');
    if v_step < 0.01 or v_min >= v_max or (v_max - v_min) / v_step > 1000
       or mod(v_max - v_min, v_step) <> 0 or v_ans < v_min or v_ans > v_max or mod(v_ans - v_min, v_step) <> 0
       or v_margin < 0 or v_margin > v_max - v_min or char_length(v_unit) > 12 or v_unit ~ '[<>"]' then
      return jsonb_build_object('note', 'bad_slider');
    end if;
    v_spec := jsonb_build_object('min', v_min, 'max', v_max, 'step', v_step, 'answer', v_ans, 'margin', v_margin, 'unit', v_unit);
    v_opts := '[]'::jsonb; v_correct := 0; v_set := '{}';
  else
    if jsonb_typeof(p_q->'options') is distinct from 'array' then return jsonb_build_object('note', 'bad_options'); end if;
    select jsonb_agg(regexp_replace(trim(x), '\s+', ' ', 'g') order by o) into v_opts
      from jsonb_array_elements_text(p_q->'options') with ordinality t(x, o);
    v_n := coalesce(jsonb_array_length(v_opts), 0);
    v_lo := case v_kind when 'type' then 1 when 'puzzle' then 3 else 2 end;
    v_hi := case v_kind when 'type' then 4 when 'puzzle' then 4 else 6 end;
    v_len := case v_kind when 'type' then 40 else 120 end;
    if v_n < v_lo or v_n > v_hi
       or exists (select 1 from jsonb_array_elements_text(v_opts) x where char_length(x) < 1 or char_length(x) > v_len) then
      return jsonb_build_object('note', 'bad_options');
    end if;
    -- Accepted answers and puzzle items must all be different.
    if v_kind in ('type', 'puzzle')
       and (select count(distinct public._norm(x)) from jsonb_array_elements_text(v_opts) x) <> v_n then
      return jsonb_build_object('note', 'bad_options');
    end if;
    if v_kind <> 'choice' then
      v_correct := 0; v_set := '{}';
    elsif v_multi then
      if jsonb_typeof(p_q->'correct') is distinct from 'array' then return jsonb_build_object('note', 'bad_correct'); end if;
      select array_agg(distinct (x)::int order by (x)::int) into v_set
        from jsonb_array_elements_text(p_q->'correct') x where x ~ '^\d$';
      if v_set is null or cardinality(v_set) <> jsonb_array_length(p_q->'correct')
         or v_set[cardinality(v_set)] >= v_n then
        return jsonb_build_object('note', 'bad_correct');
      end if;
      v_correct := v_set[1];
    else
      if v_correct is null or v_correct >= v_n then return jsonb_build_object('note', 'bad_correct'); end if;
      v_set := array[v_correct];
    end if;
  end if;

  if v_id is null then
    -- New questions start at 1001, clear of the ids bank.local.sql uses.
    select greatest(1000, coalesce(max(id), 0)) + 1 into v_id from public.question_bank where game_id = a.p_game;
    insert into public.question_bank (game_id, id, module, category, text, options, correct_index, correct_set, multi,
                                      kind, spec, explanation, verified, note, time_s, points)
    values (a.p_game, v_id, v_module, v_cat, v_text, v_opts, v_correct, v_set, v_multi,
            v_kind, v_spec, v_expl, v_verified, v_note, v_time, v_points)
    returning * into b;
  else
    update public.question_bank set module = v_module, category = v_cat, text = v_text, options = v_opts,
           correct_index = v_correct, correct_set = v_set, multi = v_multi, kind = v_kind, spec = v_spec,
           explanation = v_expl, verified = v_verified, note = v_note,
           time_s = v_time, points = v_points
     where game_id = a.p_game and id = v_id
    returning * into b;
    if b.id is null then return jsonb_build_object('note', 'not_found'); end if;
    if g.status = 'lobby' then
      update public.questions set category = v_cat, text = v_text, options = v_opts, correct_index = v_correct,
             correct_set = v_set, multi = v_multi, kind = v_kind, spec = v_spec,
             explanation = v_expl, time_s = v_time, points = v_points
       where game_id = a.p_game and bank_id = v_id;
      get diagnostics v_in_quiz = row_count;
    end if;
  end if;

  return jsonb_build_object('note', 'question_saved', 'quiz_updated', v_in_quiz > 0,
    'question', jsonb_build_object(
      'id', b.id, 'module', b.module, 'category', b.category, 'text', b.text, 'options', b.options,
      'correct_index', b.correct_index, 'correct_set', b.correct_set, 'multi', b.multi,
      'kind', b.kind, 'spec', b.spec,
      'explanation', b.explanation, 'verified', b.verified,
      'note', b.note, 'time_s', b.time_s, 'points', b.points));
end $$;

revoke execute on function public._norm(text) from public, anon, authenticated;
revoke execute on function public.submit_response(uuid, int, jsonb) from public;
grant execute on function public.submit_response(uuid, int, jsonb) to anon, authenticated;
grant execute on function public.submit_answers(uuid, int, int[]) to anon, authenticated;

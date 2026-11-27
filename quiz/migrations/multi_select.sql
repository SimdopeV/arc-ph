-- Up to six answers and multi-select questions, for an existing database.
-- Run once in the Supabase SQL editor. Safe to run again.
-- Does not touch players, answers, scores, the PIN or any question's wording.
-- Every existing question stays single-select.

begin;

alter table public.games add column if not exists revealed_set int[];
alter table public.games add column if not exists multi boolean not null default false;
alter table public.questions add column if not exists correct_set int[];
alter table public.questions add column if not exists multi boolean not null default false;
alter table public.question_bank add column if not exists correct_set int[];
alter table public.question_bank add column if not exists multi boolean not null default false;
alter table public.answers add column if not exists choices int[];

-- Drop the old 4-answer limits (whatever Postgres named them) and add the 6-answer ones.
do $$
declare r record;
begin
  for r in
    select c.conrelid::regclass as tbl, c.conname
      from pg_constraint c
     where c.contype = 'c'
       and c.conrelid in ('public.questions'::regclass, 'public.question_bank'::regclass, 'public.answers'::regclass)
       and pg_get_constraintdef(c.oid) ~ '(jsonb_array_length|correct_index|choice)'
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;
end $$;
alter table public.questions add constraint questions_options_n
  check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 6);
alter table public.questions add constraint questions_correct_ok
  check (correct_index between 0 and 5 and correct_index < jsonb_array_length(options));
alter table public.question_bank add constraint question_bank_options_n
  check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 6);
alter table public.question_bank add constraint question_bank_correct_ok
  check (correct_index between 0 and 5 and correct_index < jsonb_array_length(options));
alter table public.answers add constraint answers_choice_ok check (choice between 0 and 5);

create or replace function public._fix_correct()
returns trigger language plpgsql as $$
declare n int := jsonb_array_length(new.options);
begin
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

drop trigger if exists questions_fix_correct on public.questions;
create trigger questions_fix_correct before insert or update on public.questions
  for each row execute function public._fix_correct();
drop trigger if exists question_bank_fix_correct on public.question_bank;
create trigger question_bank_fix_correct before insert or update on public.question_bank
  for each row execute function public._fix_correct();

-- Fill correct_set for the questions already there.
update public.questions set correct_set = array[correct_index] where correct_set is null;
update public.question_bank set correct_set = array[correct_index] where correct_set is null;

create or replace function public._public_game(g public.games)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', g.id, 'join_code', g.join_code, 'status', g.status,
    'current_index', g.current_index, 'total_questions', g.total_questions,
    'duration_s', g.duration_s, 'category', g.category,
    'question_text', g.question_text, 'options', g.options,
    'started_at', g.started_at, 'paused_at', g.paused_at,
    'revealed_index', g.revealed_index, 'revealed_set', g.revealed_set, 'multi', g.multi,
    'explanation', g.explanation,
    'card_mode', g.card_mode, 'points', g.points, 'event_name', g.event_name, 'teams', g.teams,
    'updated_at', g.updated_at)
$$;

create or replace function public._apply(p_game uuid, p_status text, p_index int)
returns void language plpgsql security definer set search_path = public as $$
declare
  q public.questions;
  g public.games;
begin
  select * into g from public.games where id = p_game for update;
  if p_status = 'lobby' or p_index < 0 then
    update public.games set status = 'lobby', current_index = -1, category = null,
           question_text = null, options = null, started_at = null, paused_at = null,
           revealed_index = null, revealed_set = null, multi = false, explanation = null, updated_at = now()
     where id = p_game;
    return;
  end if;

  select * into q from public.questions where game_id = p_game and idx = p_index;
  if q.idx is null then raise exception 'question % not found', p_index; end if;

  update public.games set
    status         = p_status,
    current_index  = p_index,
    category       = q.category,
    question_text  = q.text,
    options        = q.options,
    duration_s     = q.time_s,
    points         = q.points,
    multi          = q.multi,
    started_at     = case
                       when p_status = 'question' and (g.status <> 'question' or g.current_index <> p_index) then now()
                       when p_status = 'question' then g.started_at
                       else coalesce(case when g.current_index = p_index then g.started_at end, now())
                     end,
    paused_at      = case when p_status = 'question' and g.status = 'question' and g.current_index = p_index
                          then g.paused_at end,
    revealed_index = case when p_status in ('reveal', 'leaderboard', 'final') then q.correct_index end,
    revealed_set   = case when p_status in ('reveal', 'leaderboard', 'final') then q.correct_set end,
    explanation    = case when p_status in ('reveal', 'leaderboard', 'final') then q.explanation end,
    updated_at     = now()
  where id = p_game;
end $$;

create or replace function public._host_view(p_game uuid, p_note text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  g public.games;
  dist jsonb := null;
  n_in int := 0;
  by_team jsonb := '{}'::jsonb;
  n_right int := 0;
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
    if g.status in ('reveal', 'leaderboard', 'final') then
      -- Votes per answer; a multi-select answer counts once for each answer ticked.
      select jsonb_agg(coalesce(c.n, 0) order by s.i) into dist
        from generate_series(0, coalesce(jsonb_array_length(g.options), 4) - 1) s(i)
        left join (select x as choice, count(*)::int n
                     from public.answers a, unnest(coalesce(a.choices, array[a.choice])) x
                    where a.game_id = p_game and a.question_idx = g.current_index
                    group by x) c on c.choice = s.i;
      select count(*) into n_right from public.answers
       where game_id = p_game and question_idx = g.current_index and is_correct;
    end if;
  end if;

  return jsonb_build_object(
    'game', public._public_game(g),
    'server_now', now(),
    'answers_in', n_in,
    'right_in', n_right,
    'team_answers', by_team,
    'distribution', dist,
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
    'choice', a.choice,
    'choices', a.choices,
    'total', me.total,
    'result', res,
    'final', fin);
end $$;

create or replace function public.submit_answers(p_player uuid, p_question_idx int, p_choices int[])
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
  v_correct boolean;
  v_points int;
begin
  select array_agg(distinct x order by x) into v_set from unnest(coalesce(p_choices, '{}')) x where x is not null;
  if v_set is null or exists (select 1 from unnest(v_set) x where x not between 0 and 5) then
    return jsonb_build_object('error', 'bad_choice');
  end if;
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
  v_n := jsonb_array_length(q.options);
  if v_set[cardinality(v_set)] >= v_n or (not q.multi and cardinality(v_set) <> 1) then
    return jsonb_build_object('error', 'bad_choice');
  end if;

  -- Right = exactly the right answers. Multi-select gives partial credit: a share of
  -- the points for each right answer ticked, but nothing if any wrong answer is ticked.
  select count(*) filter (where x = any (q.correct_set)), count(*) filter (where not (x = any (q.correct_set)))
    into v_right, v_wrong from unnest(v_set) x;
  v_correct := v_wrong = 0 and v_right = cardinality(q.correct_set);
  -- 500 to 1000 for a right answer, doubled or zeroed by the question's points setting.
  v_points := case when v_wrong = 0 and v_right > 0
                   then round((500 + round(500 * (1 - v_elapsed / g.duration_s)))
                              * v_right / cardinality(q.correct_set))::int
                        * case q.points when 'double' then 2 when 'none' then 0 else 1 end
                   else 0 end;

  insert into public.answers (game_id, player_id, question_idx, choice, choices, elapsed_ms, is_correct, points)
  values (g.id, p.id, g.current_index, v_set[1], v_set, round(v_elapsed * 1000)::int, v_correct, v_points)
  on conflict (player_id, question_idx) do nothing;

  if not found then return jsonb_build_object('error', 'duplicate'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.submit_answer(p_player uuid, p_question_idx int, p_choice int)
returns jsonb language sql security definer set search_path = public as $$
  select public.submit_answers(p_player, p_question_idx, array[p_choice])
$$;

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
      'explanation', q.explanation, 'time_s', q.time_s, 'points', q.points) order by q.idx)
    from public.questions q where q.game_id = a.p_game));
end $$;

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
        'explanation', b.explanation, 'verified', b.verified, 'note', b.note,
        'time_s', b.time_s, 'points', b.points) order by b.id)
      from public.question_bank b where b.game_id = a.p_game), '[]'::jsonb),
    'selected', coalesce((select jsonb_agg(q.bank_id order by q.idx)
      from public.questions q where q.game_id = a.p_game and q.bank_id is not null), '[]'::jsonb),
    'unlinked', (select count(*) from public.questions q where q.game_id = a.p_game and q.bank_id is null),
    'status', (select status from public.games where id = a.p_game));
end $$;

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
                                explanation, time_s, points, bank_id)
  select a.p_game, (t.ord - 1)::int, b.category, b.text, b.options, b.correct_index, b.correct_set, b.multi,
         b.explanation, b.time_s, b.points, b.id
    from unnest(p_ids) with ordinality t(id, ord)
    join public.question_bank b on b.game_id = a.p_game and b.id = t.id;
  update public.games set total_questions = n, updated_at = now() where id = a.p_game;
  return public._host_view(a.p_game, 'questions_set');
end $$;

create or replace function public.host_bank_save(p_code text, p_pin text, p_q jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record; g public.games; b public.question_bank;
  v_id int; v_text text; v_module text; v_cat text; v_expl text; v_note text;
  v_opts jsonb; v_n int; v_correct int; v_time int; v_points text; v_verified boolean;
  v_multi boolean; v_set int[];
  v_in_quiz int := 0;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;  -- one save at a time
  if p_q is null or jsonb_typeof(p_q) <> 'object' then return jsonb_build_object('note', 'bad_question'); end if;

  v_id      := case when p_q->>'id' ~ '^\d{1,6}$' then (p_q->>'id')::int end;
  v_text    := regexp_replace(trim(coalesce(p_q->>'text', '')), '\s+', ' ', 'g');
  v_module  := regexp_replace(trim(coalesce(p_q->>'module', '')), '\s+', ' ', 'g');
  v_cat     := regexp_replace(trim(coalesce(nullif(trim(p_q->>'category'), ''), v_module)), '\s+', ' ', 'g');
  v_expl    := trim(coalesce(p_q->>'explanation', ''));
  v_note    := trim(coalesce(p_q->>'note', ''));
  v_correct := case when p_q->>'correct_index' ~ '^\d$' then (p_q->>'correct_index')::int end;
  v_time    := case when p_q->>'time_s' ~ '^\d{1,3}$' then (p_q->>'time_s')::int end;
  v_points  := coalesce(p_q->>'points', 'standard');
  v_verified := coalesce(p_q->>'verified', 'false') = 'true';
  v_multi   := coalesce(p_q->>'multi', 'false') = 'true';

  if char_length(v_text) < 1 or char_length(v_text) > 200 then return jsonb_build_object('note', 'bad_text'); end if;
  if char_length(v_module) < 1 or char_length(v_module) > 40 then return jsonb_build_object('note', 'bad_module'); end if;
  if char_length(v_cat) > 30 then return jsonb_build_object('note', 'bad_category'); end if;
  if char_length(v_expl) > 400 or char_length(v_note) > 300 then return jsonb_build_object('note', 'bad_explanation'); end if;
  if v_time is null or v_time not in (5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240) then return jsonb_build_object('note', 'bad_time'); end if;
  if v_points not in ('standard', 'double', 'none') then return jsonb_build_object('note', 'bad_points'); end if;
  if jsonb_typeof(p_q->'options') is distinct from 'array' then return jsonb_build_object('note', 'bad_options'); end if;
  select jsonb_agg(regexp_replace(trim(x), '\s+', ' ', 'g') order by o) into v_opts
    from jsonb_array_elements_text(p_q->'options') with ordinality t(x, o);
  v_n := coalesce(jsonb_array_length(v_opts), 0);
  if v_n < 2 or v_n > 6 or exists (select 1 from jsonb_array_elements_text(v_opts) x
                                    where char_length(x) < 1 or char_length(x) > 120) then
    return jsonb_build_object('note', 'bad_options');
  end if;
  if v_multi then
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

  if v_id is null then
    -- New questions start at 1001, clear of the ids bank.local.sql uses.
    select greatest(1000, coalesce(max(id), 0)) + 1 into v_id from public.question_bank where game_id = a.p_game;
    insert into public.question_bank (game_id, id, module, category, text, options, correct_index, correct_set, multi,
                                      explanation, verified, note, time_s, points)
    values (a.p_game, v_id, v_module, v_cat, v_text, v_opts, v_correct, v_set, v_multi,
            v_expl, v_verified, v_note, v_time, v_points)
    returning * into b;
  else
    update public.question_bank set module = v_module, category = v_cat, text = v_text, options = v_opts,
           correct_index = v_correct, correct_set = v_set, multi = v_multi,
           explanation = v_expl, verified = v_verified, note = v_note,
           time_s = v_time, points = v_points
     where game_id = a.p_game and id = v_id
    returning * into b;
    if b.id is null then return jsonb_build_object('note', 'not_found'); end if;
    if g.status = 'lobby' then
      update public.questions set category = v_cat, text = v_text, options = v_opts, correct_index = v_correct,
             correct_set = v_set, multi = v_multi, explanation = v_expl, time_s = v_time, points = v_points
       where game_id = a.p_game and bank_id = v_id;
      get diagnostics v_in_quiz = row_count;
    end if;
  end if;

  return jsonb_build_object('note', 'question_saved', 'quiz_updated', v_in_quiz > 0,
    'question', jsonb_build_object(
      'id', b.id, 'module', b.module, 'category', b.category, 'text', b.text, 'options', b.options,
      'correct_index', b.correct_index, 'correct_set', b.correct_set, 'multi', b.multi,
      'explanation', b.explanation, 'verified', b.verified,
      'note', b.note, 'time_s', b.time_s, 'points', b.points));
end $$;

revoke execute on function public._fix_correct() from public, anon, authenticated;
revoke execute on function public.submit_answers(uuid, int, int[]) from public;
grant execute on function public.submit_answers(uuid, int, int[]) to anon, authenticated;
revoke execute on function public._host_view(uuid, text) from public, anon, authenticated;

commit;

select (select count(*) from public.question_bank where correct_set is not null) as bank_ready,
       (select count(*) from public.questions where correct_set is not null) as quiz_ready;

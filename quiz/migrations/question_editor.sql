-- Question editor: per-question time limit and points, and editing the bank
-- from the host page. For an existing database. Run once; safe to run again.
-- Does not touch players, answers, scores, the PIN or the questions' wording.
-- Every question keeps 20 seconds and standard points until you change it.

begin;

alter table public.games add column if not exists points text not null default 'standard';
alter table public.questions add column if not exists time_s int not null default 20;
alter table public.questions add column if not exists points text not null default 'standard';
alter table public.question_bank add column if not exists time_s int not null default 20;
alter table public.question_bank add column if not exists points text not null default 'standard';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'questions_time_s_check') then
    alter table public.questions add constraint questions_time_s_check check (time_s in (5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'questions_points_check') then
    alter table public.questions add constraint questions_points_check check (points in ('standard', 'double', 'none'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'question_bank_time_s_check') then
    alter table public.question_bank add constraint question_bank_time_s_check check (time_s in (5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'question_bank_points_check') then
    alter table public.question_bank add constraint question_bank_points_check check (points in ('standard', 'double', 'none'));
  end if;
end $$;

create or replace function public._public_game(g public.games)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', g.id, 'join_code', g.join_code, 'status', g.status,
    'current_index', g.current_index, 'total_questions', g.total_questions,
    'duration_s', g.duration_s, 'category', g.category,
    'question_text', g.question_text, 'options', g.options,
    'started_at', g.started_at, 'paused_at', g.paused_at,
    'revealed_index', g.revealed_index, 'explanation', g.explanation,
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
           revealed_index = null, explanation = null, updated_at = now()
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
    started_at     = case
                       when p_status = 'question' and (g.status <> 'question' or g.current_index <> p_index) then now()
                       when p_status = 'question' then g.started_at
                       else coalesce(case when g.current_index = p_index then g.started_at end, now())
                     end,
    paused_at      = case when p_status = 'question' and g.status = 'question' and g.current_index = p_index
                          then g.paused_at end,
    revealed_index = case when p_status in ('reveal', 'leaderboard', 'final') then q.correct_index end,
    explanation    = case when p_status in ('reveal', 'leaderboard', 'final') then q.explanation end,
    updated_at     = now()
  where id = p_game;
end $$;

create or replace function public.submit_answer(p_player uuid, p_question_idx int, p_choice int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p public.players;
  g public.games;
  q public.questions;
  v_elapsed numeric;
  v_correct boolean;
  v_points int;
begin
  if p_choice is null or p_choice not between 0 and 3 then
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
  if p_choice >= jsonb_array_length(q.options) then
    return jsonb_build_object('error', 'bad_choice');
  end if;
  v_correct := (p_choice = q.correct_index);
  -- 500 to 1000 for a right answer, doubled or zeroed by the question's points setting.
  v_points := case when v_correct
                   then (500 + round(500 * (1 - v_elapsed / g.duration_s))::int)
                        * case q.points when 'double' then 2 when 'none' then 0 else 1 end
                   else 0 end;

  insert into public.answers (game_id, player_id, question_idx, choice, elapsed_ms, is_correct, points)
  values (g.id, p.id, g.current_index, p_choice, round(v_elapsed * 1000)::int, v_correct, v_points)
  on conflict (player_id, question_idx) do nothing;

  if not found then return jsonb_build_object('error', 'duplicate'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.host_questions(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  return jsonb_build_object('questions', (
    select jsonb_agg(jsonb_build_object(
      'idx', q.idx, 'category', q.category, 'text', q.text, 'options', q.options,
      'correct_index', q.correct_index, 'explanation', q.explanation,
      'time_s', q.time_s, 'points', q.points) order by q.idx)
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
        'options', b.options, 'correct_index', b.correct_index, 'explanation', b.explanation,
        'verified', b.verified, 'note', b.note, 'time_s', b.time_s, 'points', b.points) order by b.id)
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
  insert into public.questions (game_id, idx, category, text, options, correct_index, explanation, time_s, points, bank_id)
  select a.p_game, (t.ord - 1)::int, b.category, b.text, b.options, b.correct_index, b.explanation, b.time_s, b.points, b.id
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
  if v_n < 2 or v_n > 4 or exists (select 1 from jsonb_array_elements_text(v_opts) x
                                    where char_length(x) < 1 or char_length(x) > 120) then
    return jsonb_build_object('note', 'bad_options');
  end if;
  if v_correct is null or v_correct >= v_n then return jsonb_build_object('note', 'bad_correct'); end if;

  if v_id is null then
    -- New questions start at 1001, clear of the ids bank.local.sql uses.
    select greatest(1000, coalesce(max(id), 0)) + 1 into v_id from public.question_bank where game_id = a.p_game;
    insert into public.question_bank (game_id, id, module, category, text, options, correct_index,
                                      explanation, verified, note, time_s, points)
    values (a.p_game, v_id, v_module, v_cat, v_text, v_opts, v_correct, v_expl, v_verified, v_note, v_time, v_points)
    returning * into b;
  else
    update public.question_bank set module = v_module, category = v_cat, text = v_text, options = v_opts,
           correct_index = v_correct, explanation = v_expl, verified = v_verified, note = v_note,
           time_s = v_time, points = v_points
     where game_id = a.p_game and id = v_id
    returning * into b;
    if b.id is null then return jsonb_build_object('note', 'not_found'); end if;
    if g.status = 'lobby' then
      update public.questions set category = v_cat, text = v_text, options = v_opts, correct_index = v_correct,
             explanation = v_expl, time_s = v_time, points = v_points
       where game_id = a.p_game and bank_id = v_id;
      get diagnostics v_in_quiz = row_count;
    end if;
  end if;

  return jsonb_build_object('note', 'question_saved', 'quiz_updated', v_in_quiz > 0,
    'question', jsonb_build_object(
      'id', b.id, 'module', b.module, 'category', b.category, 'text', b.text, 'options', b.options,
      'correct_index', b.correct_index, 'explanation', b.explanation, 'verified', b.verified,
      'note', b.note, 'time_s', b.time_s, 'points', b.points));
end $$;

create or replace function public.host_bank_delete(p_code text, p_pin text, p_id int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  delete from public.question_bank where game_id = a.p_game and id = p_id;
  if not found then return jsonb_build_object('note', 'not_found'); end if;
  update public.questions set bank_id = null where game_id = a.p_game and bank_id = p_id;
  return jsonb_build_object('note', 'question_deleted');
end $$;

create or replace function public.host_bank_set_time(p_code text, p_pin text, p_ids int[], p_time int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games; n int;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  if p_time is null or p_time not in (5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240) then
    return jsonb_build_object('note', 'bad_time');
  end if;
  select * into g from public.games where id = a.p_game;
  update public.question_bank set time_s = p_time where game_id = a.p_game and id = any (coalesce(p_ids, '{}'));
  get diagnostics n = row_count;
  if g.status = 'lobby' then
    update public.questions set time_s = p_time where game_id = a.p_game and bank_id = any (coalesce(p_ids, '{}'));
  end if;
  return jsonb_build_object('note', 'time_set', 'count', n);
end $$;

revoke execute on function public.host_bank_save(text, text, jsonb), public.host_bank_delete(text, text, int),
  public.host_bank_set_time(text, text, int[], int) from public;
grant execute on function public.host_bank_save(text, text, jsonb), public.host_bank_delete(text, text, int),
  public.host_bank_set_time(text, text, int[], int) to anon, authenticated;

commit;

select (select count(*) from public.question_bank) as bank_questions,
       (select count(*) from public.questions) as questions_in_quiz;

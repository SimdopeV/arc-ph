-- Batch 4: one picture per question.
-- Run once in the Supabase SQL editor on a database set up before this change.
-- Safe to run again. Players, answers, the quiz and the question bank are kept.
-- Pictures go in the public quiz-images bucket under random names; uploads only
-- go through the quiz-upload Edge Function (functions/quiz-upload), which checks the PIN.

alter table public.games add column if not exists image text;
alter table public.questions add column if not exists image text;
alter table public.question_bank add column if not exists image text;

do $$
declare t text;
begin
  foreach t in array array['questions', 'question_bank'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_image_ok');
    execute format($f$alter table public.%I add constraint %I check (image is null or image ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|webp|png)$')$f$, t, t || '_image_ok');
  end loop;
end $$;

create or replace function public._public_game(g public.games)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', g.id, 'join_code', g.join_code, 'status', g.status,
    'current_index', g.current_index, 'total_questions', g.total_questions,
    'duration_s', g.duration_s, 'category', g.category,
    'question_text', g.question_text, 'options', g.options,
    'started_at', g.started_at, 'paused_at', g.paused_at,
    'revealed_index', g.revealed_index, 'revealed_set', g.revealed_set, 'multi', g.multi,
    'kind', g.kind, 'spec', g.spec, 'answer', g.answer, 'image', g.image,
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
           image = null, explanation = null, updated_at = now()
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
    image          = q.image,
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
      'kind', q.kind, 'spec', q.spec, 'image', q.image,
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
        'kind', b.kind, 'spec', b.spec, 'image', b.image,
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
                                kind, spec, image, explanation, time_s, points, bank_id)
  select a.p_game, (t.ord - 1)::int, b.category, b.text, b.options, b.correct_index, b.correct_set, b.multi,
         b.kind, b.spec, b.image, b.explanation, b.time_s, b.points, b.id
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
--        image: a path from quiz-upload, or null for no picture,
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
  v_image text;
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
  v_image   := nullif(trim(coalesce(p_q->>'image', '')), '');

  if v_kind not in ('choice', 'poll', 'type', 'slider', 'puzzle') then return jsonb_build_object('note', 'bad_kind'); end if;
  if char_length(v_text) < 1 or char_length(v_text) > 200 then return jsonb_build_object('note', 'bad_text'); end if;
  if char_length(v_module) < 1 or char_length(v_module) > 40 then return jsonb_build_object('note', 'bad_module'); end if;
  if char_length(v_cat) > 30 then return jsonb_build_object('note', 'bad_category'); end if;
  if char_length(v_expl) > 400 or char_length(v_note) > 300 then return jsonb_build_object('note', 'bad_explanation'); end if;
  if v_time is null or v_time not in (5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240) then return jsonb_build_object('note', 'bad_time'); end if;
  if v_points not in ('standard', 'double', 'none') then return jsonb_build_object('note', 'bad_points'); end if;
  -- A picture uploaded through quiz-upload for this game, or none.
  if v_image is not null and (v_image !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|webp|png)$' or split_part(v_image, '/', 1) <> a.p_game::text) then
    return jsonb_build_object('note', 'bad_image');
  end if;

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
                                      kind, spec, image, explanation, verified, note, time_s, points)
    values (a.p_game, v_id, v_module, v_cat, v_text, v_opts, v_correct, v_set, v_multi,
            v_kind, v_spec, v_image, v_expl, v_verified, v_note, v_time, v_points)
    returning * into b;
  else
    update public.question_bank set module = v_module, category = v_cat, text = v_text, options = v_opts,
           correct_index = v_correct, correct_set = v_set, multi = v_multi, kind = v_kind, spec = v_spec, image = v_image,
           explanation = v_expl, verified = v_verified, note = v_note,
           time_s = v_time, points = v_points
     where game_id = a.p_game and id = v_id
    returning * into b;
    if b.id is null then return jsonb_build_object('note', 'not_found'); end if;
    if g.status = 'lobby' then
      update public.questions set category = v_cat, text = v_text, options = v_opts, correct_index = v_correct,
             correct_set = v_set, multi = v_multi, kind = v_kind, spec = v_spec, image = v_image,
             explanation = v_expl, time_s = v_time, points = v_points
       where game_id = a.p_game and bank_id = v_id;
      get diagnostics v_in_quiz = row_count;
    end if;
  end if;

  return jsonb_build_object('note', 'question_saved', 'quiz_updated', v_in_quiz > 0,
    'question', jsonb_build_object(
      'id', b.id, 'module', b.module, 'category', b.category, 'text', b.text, 'options', b.options,
      'correct_index', b.correct_index, 'correct_set', b.correct_set, 'multi', b.multi,
      'kind', b.kind, 'spec', b.spec, 'image', b.image,
      'explanation', b.explanation, 'verified', b.verified,
      'note', b.note, 'time_s', b.time_s, 'points', b.points));
end $$;

-- Called by the quiz-upload Edge Function before it hands out an upload link.
-- A wrong PIN counts towards the lockout like any other host call.
create or replace function public.host_image_check(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  return jsonb_build_object('ok', true, 'game', a.p_game);
end $$;

revoke execute on function public.host_image_check(text, text) from public;
grant execute on function public.host_image_check(text, text) to anon, authenticated;

-- The Edge Function calls host_image_check with the service role (Supabase only).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.host_image_check(text, text) to service_role;
  end if;
end $$;

-- Pictures: a public bucket (anyone with the link can view, nobody can list it).
-- Uploads only go through quiz-upload, which checks the host PIN. Supabase only.
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('quiz-images', 'quiz-images', true, 1048576, array['image/jpeg', 'image/webp', 'image/png'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;
  end if;
end $$;

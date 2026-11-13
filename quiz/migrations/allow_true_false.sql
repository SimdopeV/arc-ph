-- Allow True/False questions (2 to 4 options) on an existing database.
-- Run once in the Supabase SQL editor. Safe to run again.
-- Does not touch players, answers, scores, questions or the PIN.

begin;

-- 1. Replace the "exactly 4 options" check, whatever Postgres named it.
do $$
declare
  r record;
begin
  for r in
    select c.conname
    from pg_constraint c
    where c.contype = 'c'
      and c.conrelid = 'public.questions'::regclass
      and pg_get_constraintdef(c.oid) like '%jsonb_array_length(options)%'
  loop
    execute format('alter table public.questions drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.questions
  add constraint questions_options_check
    check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 4),
  add constraint questions_correct_in_range
    check (correct_index < jsonb_array_length(options));

-- 2. Host view: the answer bars follow the number of options.
create or replace function public._host_view(p_game uuid, p_note text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  g public.games;
  dist jsonb := null;
  n_in int := 0;
begin
  select * into g from public.games where id = p_game;
  if g.current_index >= 0 then
    select count(*) into n_in from public.answers
     where game_id = p_game and question_idx = g.current_index;
    if g.status in ('reveal', 'leaderboard', 'final') then
      select jsonb_agg(coalesce(c.n, 0) order by s.i) into dist
        from generate_series(0, coalesce(jsonb_array_length(g.options), 4) - 1) s(i)
        left join (select choice, count(*)::int n from public.answers
                    where game_id = p_game and question_idx = g.current_index
                    group by choice) c on c.choice = s.i;
    end if;
  end if;

  return jsonb_build_object(
    'game', public._public_game(g),
    'server_now', now(),
    'answers_in', n_in,
    'distribution', dist,
    'note', p_note,
    'players', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.player_id, 'name', t.name, 'label', t.label, 'group', t.group_name,
        'total', t.total, 'correct', t.correct, 'answered', t.answered, 'rank', t.rank)
        order by t.total desc, t.correct desc, t.joined_at)
      from public._player_totals(p_game) t), '[]'::jsonb),
    'groups', (select jsonb_agg(jsonb_build_object(
        'name', s.group_name, 'members', s.members, 'avg', s.avg_total,
        'card_points', s.card_points, 'score', s.score, 'correct', s.correct, 'rank', s.rank))
      from public._group_scores(p_game) s),
    'card_awards', coalesce((select jsonb_object_agg(x.question_idx, x.groups) from (
        select question_idx, jsonb_agg(group_name order by group_name) groups
        from public.card_awards where game_id = p_game group by question_idx) x), '{}'::jsonb)
  );
end $$;

-- 3. Answers: reject a choice past the last option (C or D on a True/False question).
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
  v_points := case when v_correct
                   then 500 + round(500 * (1 - v_elapsed / g.duration_s))::int
                   else 0 end;

  insert into public.answers (game_id, player_id, question_idx, choice, elapsed_ms, is_correct, points)
  values (g.id, p.id, g.current_index, p_choice, round(v_elapsed * 1000)::int, v_correct, v_points)
  on conflict (player_id, question_idx) do nothing;

  if not found then return jsonb_build_object('error', 'duplicate'); end if;
  return jsonb_build_object('ok', true);
end $$;

commit;

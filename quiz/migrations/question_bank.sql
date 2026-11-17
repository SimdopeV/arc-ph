-- Question bank, question picker and live extras, for an existing database.
-- Run once in the Supabase SQL editor. Safe to run again.
-- Does not touch players, answers, scores, the questions in play or the PIN.
-- Afterwards run bank.local.sql (kept off GitHub) to fill the bank.

begin;

-- 1. The bank, and a link from each quiz question back to its bank row.
alter table public.questions add column if not exists bank_id int;

create table if not exists public.question_bank (
  game_id       uuid not null references public.games (id) on delete cascade,
  id            int  not null,
  module        text not null,
  category      text not null,
  text          text not null,
  options       jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 4),
  correct_index int  not null check (correct_index between 0 and 3),
  check (correct_index < jsonb_array_length(options)),
  explanation   text not null default '',
  verified      boolean not null default false,  -- the answer has been checked
  note          text not null default '',
  primary key (game_id, id)
);

alter table public.question_bank enable row level security;
revoke all on public.question_bank from anon, authenticated;

-- 2. Host view: answers per team while a question is open, and each player's
--    points on the current question (for the leaderboard count-up).
create or replace function public._host_view(p_game uuid, p_note text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  g public.games;
  dist jsonb := null;
  n_in int := 0;
  by_team jsonb := '{}'::jsonb;
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

-- 3. Phones: your rank after every question, not only at the end.
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
      'is_correct', coalesce(a.is_correct, false),
      'points', coalesce(a.points, 0),
      'rank', me.rank, 'players', n_players);
  end if;

  if g.status = 'final' then
    select count(*) into n_players from public.players where game_id = g.id;
    select * into grp from public._group_scores(g.id) s where s.group_name = p.group_name;
    fin := jsonb_build_object(
      'rank', me.rank, 'players', n_players,
      'group_rank', grp.rank, 'groups', array_length(public._groups(), 1),
      'group_score', round(grp.score));
  end if;

  return jsonb_build_object(
    'player', jsonb_build_object('id', p.id, 'name', p.name, 'group', p.group_name),
    'game', public._public_game(g),
    'server_now', now(),
    'choice', a.choice,
    'total', me.total,
    'result', res,
    'final', fin);
end $$;

-- 4. The bank for the host page, and saving the chosen questions.
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
        'verified', b.verified, 'note', b.note) order by b.id)
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
  insert into public.questions (game_id, idx, category, text, options, correct_index, explanation, bank_id)
  select a.p_game, (t.ord - 1)::int, b.category, b.text, b.options, b.correct_index, b.explanation, b.id
    from unnest(p_ids) with ordinality t(id, ord)
    join public.question_bank b on b.game_id = a.p_game and b.id = t.id;
  update public.games set total_questions = n, updated_at = now() where id = a.p_game;
  return public._host_view(a.p_game, 'questions_set');
end $$;

revoke execute on function public.host_bank(text, text), public.host_set_questions(text, text, int[]) from public;
grant execute on function public.host_bank(text, text), public.host_set_questions(text, text, int[]) to anon, authenticated;

commit;

select (select count(*) from public.question_bank) as bank_questions,
       (select count(*) from public.questions) as questions_in_quiz;

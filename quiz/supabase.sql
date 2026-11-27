-- Arc PH Live Quiz: Supabase setup
-- Paste this whole file into the Supabase SQL editor and run it once.
--
-- WARNING: running it again drops and recreates every quiz table, which wipes
-- players, answers and the host PIN. Run it before the event, not during.
--
-- After it finishes:
--   1. Run questions.local.sql. It holds the questions and answers and is kept
--      off GitHub, because this repo is public.
--   2. Set the host PIN in a separate query (do not save it in any file):
--        select public.set_host_pin('ARCPH', 'your-pin-here');
--
-- Design notes
-- * anon can only SELECT the public games row (for realtime). Everything else
--   goes through security definer functions, so the browser never touches
--   questions, answers, players or game_secrets directly.
-- * The correct index lives only in questions until host_reveal copies it to
--   games.revealed_index.
-- * The player id (a random uuid kept in the phone's localStorage) acts as the
--   player's private token for player_sync and submit_answer.
-- * Host functions return jsonb. A wrong PIN returns {"error": "bad_pin"}
--   instead of raising, so the failed-attempt counter is saved.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- reset
drop table if exists public.card_awards cascade;
drop table if exists public.answers cascade;
drop table if exists public.players cascade;
drop table if exists public.question_bank cascade;
drop table if exists public.questions cascade;
drop table if exists public.game_secrets cascade;
drop table if exists public.games cascade;
drop function if exists public._groups();  -- older versions had a fixed team list

-- ---------------------------------------------------------------- tables
create table public.games (
  id              uuid primary key default gen_random_uuid(),
  join_code       text not null unique,
  status          text not null default 'lobby'
                  check (status in ('lobby', 'question', 'reveal', 'leaderboard', 'final')),
  current_index   int  not null default -1,
  total_questions int  not null default 0,
  duration_s      int  not null default 20,
  category        text,
  question_text   text,
  options         jsonb,
  started_at      timestamptz,
  paused_at       timestamptz,
  revealed_index  int,
  revealed_set    int[],            -- every right answer, once revealed (multi-select has several)
  multi           boolean not null default false,  -- the open question takes several answers
  explanation     text,
  card_mode       boolean not null default false,
  points          text not null default 'standard',  -- the open question's points: standard, double or none
  -- Set on the host page (Setup button, in the lobby).
  event_name      text not null default 'Community Meetup',
  teams           jsonb not null default '["Bobbilee", "Sam", "Tim", "Jeremy"]'::jsonb,
  updated_at      timestamptz not null default now()
);

-- Kept apart from games so no column-level trick is needed to hide it.
create table public.game_secrets (
  game_id       uuid primary key references public.games (id) on delete cascade,
  host_pin_hash text,
  fail_count    int not null default 0,
  locked_until  timestamptz
);

create table public.questions (
  game_id       uuid not null references public.games (id) on delete cascade,
  idx           int  not null,
  category      text not null,
  text          text not null,
  options       jsonb not null,
  correct_index int  not null,       -- the first right answer (kept in step by _fix_correct)
  correct_set   int[],               -- every right answer; null means just correct_index
  multi         boolean not null default false,  -- players may tick several answers
  constraint questions_options_n check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 6),
  constraint questions_correct_ok check (correct_index between 0 and 5 and correct_index < jsonb_array_length(options)),
  explanation   text not null,
  time_s        int  not null default 20 check (time_s in (5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240)),
  points        text not null default 'standard' check (points in ('standard', 'double', 'none')),
  bank_id       int,  -- which question_bank row this came from (null if loaded by hand)
  primary key (game_id, idx)
);

-- Every question you could ask. The host picks which ones go into the quiz
-- (host_set_questions copies them into questions). Filled by bank.local.sql,
-- which is kept off GitHub.
create table public.question_bank (
  game_id       uuid not null references public.games (id) on delete cascade,
  id            int  not null,
  module        text not null,
  category      text not null,
  text          text not null,
  options       jsonb not null,
  correct_index int  not null,       -- the first right answer (kept in step by _fix_correct)
  correct_set   int[],               -- every right answer; null means just correct_index
  multi         boolean not null default false,  -- players may tick several answers
  constraint question_bank_options_n check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 6),
  constraint question_bank_correct_ok check (correct_index between 0 and 5 and correct_index < jsonb_array_length(options)),
  explanation   text not null default '',
  verified      boolean not null default false,  -- the answer has been checked
  note          text not null default '',
  time_s        int  not null default 20 check (time_s in (5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240)),
  points        text not null default 'standard' check (points in ('standard', 'double', 'none')),
  primary key (game_id, id)
);

create table public.players (
  id         uuid primary key default gen_random_uuid(),
  game_id    uuid not null references public.games (id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 20),
  group_name text not null,  -- one of games.teams (checked in player_join)
  joined_at  timestamptz not null default now()
);
create index players_game_idx on public.players (game_id);

create table public.answers (
  id           bigint generated always as identity primary key,
  game_id      uuid not null references public.games (id) on delete cascade,
  player_id    uuid not null references public.players (id) on delete cascade,
  question_idx int  not null,
  choice       int  not null,        -- the first answer ticked
  choices      int[],               -- every answer ticked (multi-select)
  constraint answers_choice_ok check (choice between 0 and 5),
  answered_at  timestamptz not null default now(),
  elapsed_ms   int  not null,
  is_correct   boolean not null,
  points       int  not null,
  unique (player_id, question_idx)
);
create index answers_game_q_idx on public.answers (game_id, question_idx);

-- Card mode backup: one row per group that held up the right card.
create table public.card_awards (
  game_id      uuid not null references public.games (id) on delete cascade,
  question_idx int  not null,
  group_name   text not null,
  primary key (game_id, question_idx, group_name)
);

-- Keeps correct_index and correct_set in step, and checks the set:
-- single answer: the set is just correct_index; multi-select: sorted, no repeats,
-- at least one, each one an answer that exists.
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

create trigger questions_fix_correct before insert or update on public.questions
  for each row execute function public._fix_correct();
create trigger question_bank_fix_correct before insert or update on public.question_bank
  for each row execute function public._fix_correct();

-- ---------------------------------------------------------------- row level security
alter table public.games        enable row level security;
alter table public.game_secrets enable row level security;
alter table public.questions    enable row level security;
alter table public.question_bank enable row level security;
alter table public.players      enable row level security;
alter table public.answers      enable row level security;
alter table public.card_awards  enable row level security;

revoke all on public.games, public.game_secrets, public.questions, public.question_bank,
              public.players, public.answers, public.card_awards
  from anon, authenticated;

-- The only direct table access: read the public game row (needed for realtime).
grant select on public.games to anon, authenticated;
create policy games_public_read on public.games
  for select to anon, authenticated using (true);
-- No policies on the other tables: with RLS on and no grants, anon sees nothing.

-- Realtime: phones listen to UPDATEs on their one games row.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'games'
  ) then
    alter publication supabase_realtime add table public.games;
  end if;
end $$;

-- ---------------------------------------------------------------- internal helpers
-- These start with an underscore and are not executable by anon.

-- The teams in play, in the order the host set them (games.teams).
create or replace function public._groups(p_game uuid)
returns text[] language sql stable as $$
  select coalesce(array_agg(t.name order by t.ord), '{}')
  from public.games g, jsonb_array_elements_text(g.teams) with ordinality as t(name, ord)
  where g.id = p_game
$$;

create or replace function public._name_is_blocked(p_name text)
returns boolean language plpgsql immutable as $$
declare
  n text;
  w text;
  -- Matched anywhere in the name.
  inside text[] := array['fuck', 'fuk', 'shit', 'cunt', 'nigger', 'nigga', 'bitch', 'whore',
                         'pussy', 'faggot', 'fagot', 'motherf', 'asshole', 'bastard', 'wanker',
                         'retard', 'ashawo', 'pornhub'];
  -- Matched only as a whole word, so names like Dickson or Cassandra pass.
  whole text[] := array['ass', 'dick', 'cock', 'sex', 'porn', 'rape', 'rapist', 'penis',
                        'vagina', 'boobs', 'tits', 'slut', 'hoe', 'fag', 'nude', 'nudes',
                        'hitler', 'nazi'];
begin
  n := lower(coalesce(p_name, ''));
  n := translate(n, '0134578@$!|', 'oieastbasii');
  foreach w in array inside loop
    if position(w in regexp_replace(n, '[^a-z]', '', 'g')) > 0 then return true; end if;
  end loop;
  foreach w in array whole loop
    if n ~ ('(^|[^a-z])' || w || '([^a-z]|$)') then return true; end if;
  end loop;
  return false;
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
    'explanation', g.explanation,
    'card_mode', g.card_mode, 'points', g.points, 'event_name', g.event_name, 'teams', g.teams,
    'updated_at', g.updated_at)
$$;

-- Player totals with leaderboard labels ("Ada (2)") and rank.
create or replace function public._player_totals(p_game uuid)
returns table (player_id uuid, name text, group_name text, total int, correct int,
               answered int, joined_at timestamptz, label text, rank int)
language sql stable as $$
  with t as (
    select p.id, p.name, p.group_name, p.joined_at,
           coalesce(sum(a.points), 0)::int as total,
           count(a.id) filter (where a.is_correct)::int as correct,
           count(a.id)::int as answered
    from public.players p
    left join public.answers a on a.player_id = p.id
    where p.game_id = p_game
    group by p.id
  ), n as (
    select t.*,
           row_number() over (partition by lower(t.name) order by t.joined_at, t.id) as dup
    from t
  )
  select n.id, n.name, n.group_name, n.total, n.correct, n.answered, n.joined_at,
         case when n.dup > 1 then n.name || ' (' || n.dup || ')' else n.name end,
         (rank() over (order by n.total desc))::int
  from n
$$;

-- Group score = average of members' totals (members who never answered count
-- as 0) plus 100 per card-mode award. Tie-break: more correct answers.
create or replace function public._group_scores(p_game uuid)
returns table (group_name text, members int, avg_total numeric, card_points int,
               score numeric, correct int, rank int)
language sql stable as $$
  with gs as (
    select x.group_name, x.ord from unnest(public._groups(p_game)) with ordinality as x(group_name, ord)
  ), pt as (
    select * from public._player_totals(p_game)
  ), agg as (
    select gs.group_name, gs.ord,
           count(pt.player_id)::int as members,
           coalesce(avg(pt.total), 0)::numeric as avg_total,
           coalesce(sum(pt.correct), 0)::int as phone_correct
    from gs left join pt on pt.group_name = gs.group_name
    group by gs.group_name, gs.ord
  ), cards as (
    select ca.group_name, count(*)::int as n
    from public.card_awards ca where ca.game_id = p_game
    group by ca.group_name
  )
  select agg.group_name, agg.members, round(agg.avg_total, 2),
         coalesce(cards.n, 0) * 100,
         round(agg.avg_total + coalesce(cards.n, 0) * 100, 2),
         agg.phone_correct + coalesce(cards.n, 0),
         (rank() over (order by agg.avg_total + coalesce(cards.n, 0) * 100 desc,
                                agg.phone_correct + coalesce(cards.n, 0) desc))::int
  from agg left join cards on cards.group_name = agg.group_name
  order by agg.ord
$$;

-- Checks the host PIN. Returns the game id, or null on any failure (with the
-- reason in p_err). Never raises, so the failure counter update is kept.
create or replace function public._host_auth(p_code text, p_pin text, out p_game uuid, out p_err text)
language plpgsql security definer set search_path = public, extensions as $$
declare
  s public.game_secrets;
begin
  select g.id into p_game from public.games g where g.join_code = upper(trim(p_code));
  if p_game is null then p_err := 'game_not_found'; return; end if;

  select * into s from public.game_secrets where game_id = p_game for update;
  if s.host_pin_hash is null then p_game := null; p_err := 'pin_not_set'; return; end if;
  if s.locked_until is not null and s.locked_until > now() then
    p_game := null; p_err := 'locked'; return;
  end if;

  if extensions.crypt(coalesce(p_pin, ''), s.host_pin_hash) = s.host_pin_hash then
    if s.fail_count > 0 or s.locked_until is not null then
      update public.game_secrets set fail_count = 0, locked_until = null where game_id = p_game;
    end if;
    return;
  end if;

  -- 10 wrong PINs in a row lock host actions for 60 seconds.
  update public.game_secrets
     set fail_count   = case when fail_count + 1 >= 10 then 0 else fail_count + 1 end,
         locked_until = case when fail_count + 1 >= 10 then now() + interval '60 seconds' else null end
   where game_id = p_game;
  p_game := null;
  p_err := 'bad_pin';
end $$;

-- Moves the game to a status and question, loading the question fields from
-- questions. The correct index is copied only for reveal, leaderboard, final.
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

-- ---------------------------------------------------------------- admin (SQL editor only)
create or replace function public.set_host_pin(p_code text, p_pin text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare g_id uuid;
begin
  if p_pin is null or char_length(p_pin) < 6 then
    raise exception 'Use a PIN of at least 6 characters.';
  end if;
  select id into g_id from public.games where join_code = upper(trim(p_code));
  if g_id is null then raise exception 'No game with code %', p_code; end if;
  insert into public.game_secrets (game_id, host_pin_hash)
  values (g_id, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)))
  on conflict (game_id) do update
    set host_pin_hash = excluded.host_pin_hash, fail_count = 0, locked_until = null;
  return 'Host PIN set for ' || upper(trim(p_code));
end $$;

-- ---------------------------------------------------------------- player functions

create or replace function public.player_join(p_code text, p_name text, p_group text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g public.games;
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_id uuid;
begin
  select * into g from public.games where join_code = upper(trim(p_code));
  if g.id is null then return jsonb_build_object('error', 'game_not_found'); end if;
  if char_length(v_name) < 1 then return jsonb_build_object('error', 'name_required'); end if;
  if char_length(v_name) > 20 then return jsonb_build_object('error', 'name_too_long'); end if;
  if public._name_is_blocked(v_name) then return jsonb_build_object('error', 'name_blocked'); end if;
  if not (p_group = any (public._groups(g.id))) then return jsonb_build_object('error', 'bad_group'); end if;
  if (select count(*) from public.players where game_id = g.id) >= 300 then
    return jsonb_build_object('error', 'game_full');
  end if;

  insert into public.players (game_id, name, group_name) values (g.id, v_name, p_group)
  returning id into v_id;
  return jsonb_build_object('player_id', v_id, 'name', v_name, 'group', p_group);
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

-- Scores the answer with server time. The client never sees the correct index.
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

-- One answer (single-select questions; kept for phones still on the old page).
create or replace function public.submit_answer(p_player uuid, p_question_idx int, p_choice int)
returns jsonb language sql security definer set search_path = public as $$
  select public.submit_answers(p_player, p_question_idx, array[p_choice])
$$;

-- ---------------------------------------------------------------- host functions
-- Each takes the join code and PIN. Transition functions also take the status
-- and index the host page is showing, so a double press cannot skip ahead.

create or replace function public.host_login(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  return public._host_view(a.p_game);
end $$;

create or replace function public.host_state(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  return public._host_view(a.p_game);
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
      'explanation', q.explanation, 'time_s', q.time_s, 'points', q.points) order by q.idx)
    from public.questions q where q.game_id = a.p_game));
end $$;

create or replace function public.host_open_question(p_code text, p_pin text, p_from_status text,
                                                     p_from_index int, p_index int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.status <> p_from_status or g.current_index <> p_from_index then
    return public._host_view(a.p_game, 'stale');
  end if;
  if p_index < 0 or p_index >= g.total_questions then
    return public._host_view(a.p_game, 'no_such_question');
  end if;
  perform public._apply(a.p_game, 'question', p_index);
  return public._host_view(a.p_game);
end $$;

create or replace function public.host_start(p_code text, p_pin text)
returns jsonb language sql security definer set search_path = public as $$
  select public.host_open_question(p_code, p_pin, 'lobby', -1, 0)
$$;

create or replace function public.host_reveal(p_code text, p_pin text, p_index int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.status <> 'question' or g.current_index <> p_index then
    return public._host_view(a.p_game, 'stale');
  end if;
  perform public._apply(a.p_game, 'reveal', p_index);
  return public._host_view(a.p_game);
end $$;

-- lobby -> Q1, question -> reveal, reveal -> leaderboard,
-- leaderboard -> next question (or final after the last one).
create or replace function public.host_next(p_code text, p_pin text, p_from_status text, p_from_index int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.status <> p_from_status or g.current_index <> p_from_index then
    return public._host_view(a.p_game, 'stale');
  end if;

  if g.status = 'lobby' then
    perform public._apply(a.p_game, 'question', 0);
  elsif g.status = 'question' then
    perform public._apply(a.p_game, 'reveal', g.current_index);
  elsif g.status = 'reveal' then
    perform public._apply(a.p_game, 'leaderboard', g.current_index);
  elsif g.status = 'leaderboard' then
    if g.current_index + 1 < g.total_questions then
      perform public._apply(a.p_game, 'question', g.current_index + 1);
    else
      perform public._apply(a.p_game, 'final', g.current_index);
    end if;
  end if;
  return public._host_view(a.p_game);
end $$;

-- leaderboard -> reveal, final -> leaderboard. An open question is cancelled
-- (its answers are deleted) and the game goes back to the previous
-- leaderboard, or the lobby. A reveal cannot be undone.
create or replace function public.host_back(p_code text, p_pin text, p_from_status text, p_from_index int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.status <> p_from_status or g.current_index <> p_from_index then
    return public._host_view(a.p_game, 'stale');
  end if;

  if g.status = 'leaderboard' then
    perform public._apply(a.p_game, 'reveal', g.current_index);
  elsif g.status = 'final' then
    perform public._apply(a.p_game, 'leaderboard', greatest(g.current_index, 0));
  elsif g.status = 'question' then
    delete from public.answers where game_id = a.p_game and question_idx = g.current_index;
    delete from public.card_awards where game_id = a.p_game and question_idx = g.current_index;
    if g.current_index = 0 then
      perform public._apply(a.p_game, 'lobby', -1);
    else
      perform public._apply(a.p_game, 'leaderboard', g.current_index - 1);
    end if;
  elsif g.status = 'reveal' then
    return public._host_view(a.p_game, 'cannot_unreveal');
  end if;
  return public._host_view(a.p_game);
end $$;

-- Pause or resume the timer of the open question.
create or replace function public.host_pause(p_code text, p_pin text, p_index int, p_paused boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.status <> 'question' or g.current_index <> p_index then
    return public._host_view(a.p_game, 'stale');
  end if;
  if p_paused and g.paused_at is null then
    update public.games set paused_at = now(), updated_at = now() where id = a.p_game;
  elsif not p_paused and g.paused_at is not null then
    update public.games set started_at = started_at + (now() - paused_at), paused_at = null,
           updated_at = now() where id = a.p_game;
  end if;
  return public._host_view(a.p_game);
end $$;

create or replace function public.host_end(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.current_index < 0 then
    update public.games set status = 'final', updated_at = now() where id = a.p_game;
  else
    perform public._apply(a.p_game, 'final', g.current_index);
  end if;
  return public._host_view(a.p_game);
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
                                explanation, time_s, points, bank_id)
  select a.p_game, (t.ord - 1)::int, b.category, b.text, b.options, b.correct_index, b.correct_set, b.multi,
         b.explanation, b.time_s, b.points, b.id
    from unnest(p_ids) with ordinality t(id, ord)
    join public.question_bank b on b.game_id = a.p_game and b.id = t.id;
  update public.games set total_questions = n, updated_at = now() where id = a.p_game;
  return public._host_view(a.p_game, 'questions_set');
end $$;

-- Question editor on the host page: add or change one bank question.
-- p_q: { id (null for a new one), module, category, text, options: [2-4 strings],
--        correct_index, correct: [right answers, for multi], multi,
--        explanation, note, verified, time_s, points }
-- If the game is in the lobby and the question is in the quiz, the quiz copy is updated too.
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

-- Removes a question from the bank. A copy already in the quiz stays in the quiz.
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

-- "Apply to all questions": one time limit for every question listed (the quiz being built).
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

-- The event name and the teams, set by the host in the lobby.
-- Teams: 2 to 20, each 1 to 20 characters, no repeats. A team that already has
-- players cannot be removed or renamed (remove the players or reset first).
create or replace function public.host_set_setup(p_code text, p_pin text, p_event text, p_teams text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record; g public.games;
  v_event text := regexp_replace(trim(coalesce(p_event, '')), '\s+', ' ', 'g');
  v_teams text[];
  n int;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.status <> 'lobby' then return public._host_view(a.p_game, 'not_in_lobby'); end if;
  if char_length(v_event) < 1 or char_length(v_event) > 40 then
    return public._host_view(a.p_game, 'bad_event');
  end if;
  select coalesce(array_agg(x.name order by x.ord), '{}') into v_teams
    from (select regexp_replace(trim(t.name), '\s+', ' ', 'g') as name, t.ord
            from unnest(coalesce(p_teams, '{}')) with ordinality as t(name, ord)) x
   where x.name <> '';
  n := coalesce(array_length(v_teams, 1), 0);
  if n < 2 or n > 20 then return public._host_view(a.p_game, 'bad_team_count'); end if;
  if exists (select 1 from unnest(v_teams) x
              where char_length(x) > 20 or x ~ '[<>"]' or public._name_is_blocked(x))
     or (select count(distinct lower(x)) from unnest(v_teams) x) <> n then
    return public._host_view(a.p_game, 'bad_teams');
  end if;
  if exists (select 1 from public.players p
              where p.game_id = a.p_game and not (p.group_name = any (v_teams))) then
    return public._host_view(a.p_game, 'team_in_use');
  end if;
  delete from public.card_awards where game_id = a.p_game and not (group_name = any (v_teams));
  update public.games set event_name = v_event, teams = to_jsonb(v_teams), updated_at = now()
   where id = a.p_game;
  return public._host_view(a.p_game, 'setup_saved');
end $$;

-- Wipes players, answers and card awards and returns to the lobby.
create or replace function public.host_reset(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  delete from public.card_awards where game_id = a.p_game;
  delete from public.answers where game_id = a.p_game;
  delete from public.players where game_id = a.p_game;
  update public.games set card_mode = false where id = a.p_game;
  perform public._apply(a.p_game, 'lobby', -1);
  return public._host_view(a.p_game);
end $$;

create or replace function public.host_remove_player(p_code text, p_pin text, p_player uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  delete from public.players where id = p_player and game_id = a.p_game;
  return public._host_view(a.p_game);
end $$;

create or replace function public.host_set_card_mode(p_code text, p_pin text, p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  update public.games set card_mode = coalesce(p_on, false), updated_at = now()
   where id = a.p_game and card_mode is distinct from coalesce(p_on, false);
  return public._host_view(a.p_game);
end $$;

-- Card mode: replace the list of groups that answered question p_index right.
create or replace function public.host_card_set(p_code text, p_pin text, p_index int, p_groups text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  delete from public.card_awards where game_id = a.p_game and question_idx = p_index;
  insert into public.card_awards (game_id, question_idx, group_name)
  select a.p_game, p_index, x from unnest(coalesce(p_groups, '{}')) x
  where x = any (public._groups(a.p_game))
  on conflict do nothing;
  return public._host_view(a.p_game);
end $$;

-- Card mode: the host page runs the flow locally and pushes its position here
-- so phones follow whenever the internet is up.
create or replace function public.host_goto(p_code text, p_pin text, p_status text, p_index int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record; g public.games;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if p_status not in ('lobby', 'question', 'reveal', 'leaderboard', 'final') then
    return public._host_view(a.p_game, 'bad_status');
  end if;
  if p_status <> 'lobby' and (p_index < 0 or p_index >= g.total_questions) then
    return public._host_view(a.p_game, 'no_such_question');
  end if;
  if g.status is distinct from p_status or g.current_index is distinct from p_index then
    perform public._apply(a.p_game, p_status, p_index);
  end if;
  return public._host_view(a.p_game);
end $$;

-- ---------------------------------------------------------------- execute grants
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.player_join(text, text, text),
  public.player_sync(uuid),
  public.submit_answer(uuid, int, int),
  public.submit_answers(uuid, int, int[]),
  public.host_login(text, text),
  public.host_state(text, text),
  public.host_questions(text, text),
  public.host_bank(text, text),
  public.host_set_questions(text, text, int[]),
  public.host_set_setup(text, text, text, text[]),
  public.host_bank_save(text, text, jsonb),
  public.host_bank_delete(text, text, int),
  public.host_bank_set_time(text, text, int[], int),
  public.host_start(text, text),
  public.host_open_question(text, text, text, int, int),
  public.host_reveal(text, text, int),
  public.host_next(text, text, text, int),
  public.host_back(text, text, text, int),
  public.host_pause(text, text, int, boolean),
  public.host_end(text, text),
  public.host_reset(text, text),
  public.host_remove_player(text, text, uuid),
  public.host_set_card_mode(text, text, boolean),
  public.host_card_set(text, text, int, text[]),
  public.host_goto(text, text, text, int)
to anon, authenticated;

-- ---------------------------------------------------------------- the game
-- The questions live in bank.local.sql (the full bank; pick from it on the host page)
-- or questions.local.sql (a fixed set). Both are kept off GitHub.
insert into public.games (join_code, total_questions) values ('ARCPH', 0);



insert into public.game_secrets (game_id) select id from public.games where join_code = 'ARCPH';

-- Done. Next:
--   1. Run questions.local.sql (the questions and answers, not in the repo).
--   2. In a new query: select public.set_host_pin('ARCPH', 'your-pin-here');

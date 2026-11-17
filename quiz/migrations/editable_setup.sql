-- Editable event name and teams, for an existing database.
-- Run once in the Supabase SQL editor. Safe to run again.
-- Does not touch players, answers, scores, the questions or the PIN.
-- The teams stay as they are until you change them on the host page (Setup).

begin;

alter table public.games add column if not exists event_name text not null default 'Community Meetup';
alter table public.games add column if not exists teams jsonb not null default '["Bobbilee", "Sam", "Tim", "Jeremy"]'::jsonb;

-- Team names are no longer a fixed list, so drop the old checks on them.
do $$
declare r record;
begin
  for r in
    select c.conrelid::regclass as tbl, c.conname
      from pg_constraint c
     where c.contype = 'c'
       and c.conrelid in ('public.players'::regclass, 'public.card_awards'::regclass)
       and pg_get_constraintdef(c.oid) like '%group_name%'
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;
end $$;

create or replace function public._groups(p_game uuid)
returns text[] language sql stable as $$
  select coalesce(array_agg(t.name order by t.ord), '{}')
  from public.games g, jsonb_array_elements_text(g.teams) with ordinality as t(name, ord)
  where g.id = p_game
$$;

create or replace function public._public_game(g public.games)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', g.id, 'join_code', g.join_code, 'status', g.status,
    'current_index', g.current_index, 'total_questions', g.total_questions,
    'duration_s', g.duration_s, 'category', g.category,
    'question_text', g.question_text, 'options', g.options,
    'started_at', g.started_at, 'paused_at', g.paused_at,
    'revealed_index', g.revealed_index, 'explanation', g.explanation,
    'card_mode', g.card_mode, 'event_name', g.event_name, 'teams', g.teams,
    'updated_at', g.updated_at)
$$;

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
      'group_rank', grp.rank, 'groups', array_length(public._groups(g.id), 1),
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

drop function if exists public._groups();

revoke execute on function public._groups(uuid), public.host_set_setup(text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.host_set_setup(text, text, text, text[]) to anon, authenticated;

commit;

select event_name, teams from public.games where join_code = 'ARCPH';

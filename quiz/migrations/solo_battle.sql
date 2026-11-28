-- Solo battle: a Setup switch for events without teams.
-- Run once in the Supabase SQL editor. Safe to run again. Players, scores and questions are kept.

alter table public.games add column if not exists solo boolean not null default false;

-- host_set_setup gains a p_solo argument; drop the old four-argument version so calls stay unambiguous.
drop function if exists public.host_set_setup(text, text, text, text[]);

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
    'card_mode', g.card_mode, 'points', g.points, 'event_name', g.event_name, 'teams', g.teams, 'solo', g.solo,
    'updated_at', g.updated_at)
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
  -- Solo battle: no team to pick.
  if g.solo then p_group := '';
  elsif p_group is null or not (p_group = any (public._groups(g.id))) then return jsonb_build_object('error', 'bad_group'); end if;
  if (select count(*) from public.players where game_id = g.id) >= 300 then
    return jsonb_build_object('error', 'game_full');
  end if;

  insert into public.players (game_id, name, group_name) values (g.id, v_name, p_group)
  returning id into v_id;
  return jsonb_build_object('player_id', v_id, 'name', v_name, 'group', p_group, 'solo', g.solo);
end $$;

-- The event name, the teams and solo battle, set by the host in the lobby.
-- Teams: 2 to 20, each 1 to 20 characters, no repeats. A team that already has
-- players cannot be removed or renamed (remove the players or reset first).
-- Solo battle (p_solo): players join with a name only and there are no team scores.
-- It can only be switched while nobody has joined.
create or replace function public.host_set_setup(p_code text, p_pin text, p_event text, p_teams text[], p_solo boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record; g public.games;
  v_event text := regexp_replace(trim(coalesce(p_event, '')), '\s+', ' ', 'g');
  v_teams text[];
  v_solo boolean;
  n int;
begin
  a := public._host_auth(p_code, p_pin);
  if a.p_game is null then return jsonb_build_object('error', a.p_err); end if;
  select * into g from public.games where id = a.p_game for update;
  if g.status <> 'lobby' then return public._host_view(a.p_game, 'not_in_lobby'); end if;
  v_solo := coalesce(p_solo, g.solo);
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
  if v_solo is distinct from g.solo and exists (select 1 from public.players p where p.game_id = a.p_game) then
    return public._host_view(a.p_game, 'players_in');
  end if;
  if not v_solo and exists (select 1 from public.players p
              where p.game_id = a.p_game and not (p.group_name = any (v_teams))) then
    return public._host_view(a.p_game, 'team_in_use');
  end if;
  delete from public.card_awards where game_id = a.p_game and not (group_name = any (v_teams));
  update public.games set event_name = v_event, teams = to_jsonb(v_teams), solo = v_solo,
         card_mode = card_mode and not v_solo, updated_at = now()
   where id = a.p_game;
  return public._host_view(a.p_game, 'setup_saved');
end $$;

revoke execute on function public.host_set_setup(text, text, text, text[], boolean) from public;
grant execute on function public.host_set_setup(text, text, text, text[], boolean) to anon, authenticated;

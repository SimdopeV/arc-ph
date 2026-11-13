-- Play with four teams: Bobbilee, Sam, Tim and Jeremy (Ogbomoso, 13 Nov 2026).
-- Run once in the Supabase SQL editor. Safe to run again.
-- The check constraints still allow Rachel and Blessing, so old rows stay valid.
-- To go back to six teams, put Rachel and Blessing back in _groups() below.

begin;

-- 1. The teams players can join, and the ones that get team scores and card points.
create or replace function public._groups()
returns text[] language sql immutable as $$
  select array['Bobbilee', 'Sam', 'Tim', 'Jeremy']
$$;

-- 2. Phones: the final summary says "2nd of 4" instead of "of 6".
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
    res := jsonb_build_object(
      'question_idx', g.current_index,
      'answered', a.id is not null,
      'choice', a.choice,
      'is_correct', coalesce(a.is_correct, false),
      'points', coalesce(a.points, 0));
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

commit;

select public._groups() as teams;

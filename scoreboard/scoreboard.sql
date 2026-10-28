-- Arc PH all-day scoreboard: Supabase setup
-- Paste this whole file into the Supabase SQL editor of the quiz project and run it.
--
-- It only ADDS things: the scoreboard_* tables and the _sb_* / sb_* functions.
-- It never drops, changes or renames anything the quiz uses.
--
-- Safe to run again: it keeps the awards, totals, timer, segment and keeper PIN.
--
-- After it finishes, set the keeper PIN in a separate query (do not save it in
-- any file; it is not the quiz host PIN):
--   select public.sb_set_keeper_pin('ARCPH', 'your-keeper-pin');
--
-- If you ever run quiz/supabase.sql again, run this file again afterwards. The
-- quiz file revokes execute on every function in public, which includes these.
--
-- Design notes (same pattern as the quiz)
-- * anon can only SELECT the one public scoreboard_state row (for realtime).
--   Awards and the PIN hash have no grants, so the browser cannot read them.
-- * Every write is a security definer function that checks the keeper PIN.
--   A wrong PIN returns {"error": "bad_pin", "message": ...} instead of
--   raising, so the failed-attempt counter is saved.
-- * Every write recomputes totals from the awards that are not undone and
--   updates the state row, so the TV only has to listen to that row.
-- * rev goes up by one on every write. Pages ignore a row older than the one
--   they already show.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- tables
create table if not exists public.scoreboard_state (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  totals            jsonb not null default '{}'::jsonb,
  last_award        jsonb,
  segment           text not null default 'Setup',
  timer_label       text not null default '',
  timer_duration_s  int  not null default 0,
  timer_ends_at     timestamptz,
  timer_remaining_s numeric(10, 3),
  timer_running     boolean not null default false,
  rev               bigint not null default 0,
  updated_at        timestamptz not null default now()
);

create table if not exists public.scoreboard_awards (
  id         bigint generated always as identity primary key,
  board_id   uuid not null references public.scoreboard_state (id) on delete cascade,
  group_name text not null check (group_name in ('Bobbilee', 'Sam', 'Tim', 'Rachel', 'Jeremy', 'Blessing')),
  points     int  not null check (points <> 0 and points between -10000 and 10000),
  game_key   text not null check (game_key ~ '^[a-z0-9_]{1,24}$'),
  label      text not null check (char_length(label) between 1 and 80),
  created_at timestamptz not null default now(),
  undone     boolean not null default false,
  undone_at  timestamptz
);
create index if not exists scoreboard_awards_board_idx on public.scoreboard_awards (board_id, id desc);

-- Kept apart from scoreboard_state so the public row never holds the hash.
create table if not exists public.scoreboard_secrets (
  board_id        uuid primary key references public.scoreboard_state (id) on delete cascade,
  keeper_pin_hash text,
  fail_count      int not null default 0,
  locked_until    timestamptz
);

-- ---------------------------------------------------------------- row level security
alter table public.scoreboard_state   enable row level security;
alter table public.scoreboard_awards  enable row level security;
alter table public.scoreboard_secrets enable row level security;

revoke all on public.scoreboard_state, public.scoreboard_awards, public.scoreboard_secrets
  from anon, authenticated;

-- The only direct table access: read the public state row (needed for realtime).
grant select on public.scoreboard_state to anon, authenticated;
drop policy if exists scoreboard_state_public_read on public.scoreboard_state;
create policy scoreboard_state_public_read on public.scoreboard_state
  for select to anon, authenticated using (true);
-- No policies on awards or secrets: with RLS on and no grants, anon sees nothing.

-- Realtime: the TV and the keeper phones listen to UPDATEs on the state row.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'scoreboard_state'
  ) then
    alter publication supabase_realtime add table public.scoreboard_state;
  end if;
end $$;

-- ---------------------------------------------------------------- internal helpers
-- These start with an underscore and are not executable by anon.

create or replace function public._sb_groups()
returns text[] language sql immutable as $$
  select array['Bobbilee', 'Sam', 'Tim', 'Rachel', 'Jeremy', 'Blessing']
$$;

-- The "Now" label on the TV. Keep in step with SEGMENTS in scoreboard.js.
create or replace function public._sb_segments()
returns text[] language sql immutable as $$
  select array['Setup', 'Check-in', 'Welcome', 'Prompt Battle', 'Spot the Bug',
               'Break and Builder Bingo', 'Group quiz', 'Deploy', 'Agent demo',
               'Builder pitches', 'Scores and prizes', 'Networking']
$$;

-- Checks the keeper PIN. Returns the board id, or null on any failure with a
-- code in p_err and a sentence for the keeper in p_msg. Never raises, so the
-- failure counter update is kept.
create or replace function public._sb_auth(p_code text, p_pin text,
                                           out p_board uuid, out p_err text, out p_msg text)
language plpgsql security definer set search_path = public, extensions as $$
declare
  s public.scoreboard_secrets;
  v_left int;
begin
  select b.id into p_board from public.scoreboard_state b where b.code = upper(trim(p_code));
  if p_board is null then
    p_err := 'board_not_found'; p_msg := 'No scoreboard with that code. Run scoreboard.sql.'; return;
  end if;

  select * into s from public.scoreboard_secrets where board_id = p_board for update;
  if s.keeper_pin_hash is null then
    p_board := null; p_err := 'pin_not_set';
    p_msg := 'The keeper PIN is not set yet. Run sb_set_keeper_pin in the SQL editor.'; return;
  end if;
  if s.locked_until is not null and s.locked_until > now() then
    p_board := null; p_err := 'locked';
    p_msg := 'Too many wrong PINs. Try again in '
             || ceil(extract(epoch from (s.locked_until - now())))::int || ' seconds.';
    return;
  end if;

  if extensions.crypt(coalesce(p_pin, ''), s.keeper_pin_hash) = s.keeper_pin_hash then
    if s.fail_count > 0 or s.locked_until is not null then
      update public.scoreboard_secrets set fail_count = 0, locked_until = null where board_id = p_board;
    end if;
    return;
  end if;

  -- 10 wrong PINs in a row lock the keeper for 60 seconds.
  update public.scoreboard_secrets
     set fail_count   = case when fail_count + 1 >= 10 then 0 else fail_count + 1 end,
         locked_until = case when fail_count + 1 >= 10 then now() + interval '60 seconds' else null end
   where board_id = p_board;
  v_left := 10 - (s.fail_count + 1);
  p_board := null;
  p_err := 'bad_pin';
  p_msg := case when v_left <= 0 then 'Wrong PIN. The keeper is locked for 60 seconds.'
                when v_left = 1 then 'Wrong PIN. 1 try left before a 60 second lock.'
                else 'Wrong PIN. ' || v_left || ' tries left before a 60 second lock.' end;
end $$;

-- Recomputes totals and last_award from the awards that are not undone.
create or replace function public._sb_refresh(p_board uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.scoreboard_state b set
    totals = (
      select jsonb_object_agg(g.name, coalesce(t.points, 0))
      from unnest(public._sb_groups()) g(name)
      left join (select a.group_name, sum(a.points)::int as points
                 from public.scoreboard_awards a
                 where a.board_id = p_board and not a.undone
                 group by a.group_name) t on t.group_name = g.name),
    last_award = (
      select jsonb_build_object('id', a.id, 'group', a.group_name, 'points', a.points,
                                'game_key', a.game_key, 'label', a.label, 'at', a.created_at)
      from public.scoreboard_awards a
      where a.board_id = p_board and not a.undone
      order by a.id desc limit 1),
    rev = b.rev + 1,
    updated_at = now()
  where b.id = p_board;
end $$;

-- What the keeper page needs: the public row, the last 10 awards and the
-- server clock.
create or replace function public._sb_view(p_board uuid, p_note text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'state', to_jsonb(b),
    'server_now', now(),
    'note', p_note,
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'group', a.group_name, 'points', a.points, 'game_key', a.game_key,
               'label', a.label, 'at', a.created_at, 'undone', a.undone) order by a.id desc)
      from (select * from public.scoreboard_awards
            where board_id = p_board order by id desc limit 10) a), '[]'::jsonb))
  from public.scoreboard_state b where b.id = p_board
$$;

-- ---------------------------------------------------------------- admin (SQL editor only)
create or replace function public.sb_set_keeper_pin(p_code text, p_pin text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare b_id uuid;
begin
  if p_pin is null or char_length(p_pin) < 6 then
    raise exception 'Use a PIN of at least 6 characters.';
  end if;
  select id into b_id from public.scoreboard_state where code = upper(trim(p_code));
  if b_id is null then raise exception 'No scoreboard with code %', p_code; end if;
  insert into public.scoreboard_secrets (board_id, keeper_pin_hash)
  values (b_id, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)))
  on conflict (board_id) do update
    set keeper_pin_hash = excluded.keeper_pin_hash, fail_count = 0, locked_until = null;
  return 'Keeper PIN set for ' || upper(trim(p_code));
end $$;

-- ---------------------------------------------------------------- public
-- The TV corrects for its own clock drift with this.
create or replace function public.sb_server_time()
returns timestamptz language sql stable as $$
  select now()
$$;

-- ---------------------------------------------------------------- keeper functions
-- Each takes the board code and the keeper PIN, and returns _sb_view.

create or replace function public.sb_keeper_state(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._sb_auth(p_code, p_pin);
  if a.p_board is null then return jsonb_build_object('error', a.p_err, 'message', a.p_msg); end if;
  return public._sb_view(a.p_board);
end $$;

create or replace function public.sb_award(p_code text, p_pin text, p_group text, p_points int,
                                           p_game_key text, p_label text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record;
  v_label text := left(regexp_replace(trim(coalesce(p_label, '')), '\s+', ' ', 'g'), 80);
  v_id bigint;
begin
  a := public._sb_auth(p_code, p_pin);
  if a.p_board is null then return jsonb_build_object('error', a.p_err, 'message', a.p_msg); end if;
  if p_group is null or not (p_group = any (public._sb_groups())) then
    return jsonb_build_object('error', 'bad_group', 'message', 'Unknown group.');
  end if;
  if p_points is null or p_points = 0 or abs(p_points) > 10000 then
    return jsonb_build_object('error', 'bad_points', 'message', 'Points must be between -10000 and 10000, and not 0.');
  end if;
  if p_game_key is null or p_game_key !~ '^[a-z0-9_]{1,24}$' then
    return jsonb_build_object('error', 'bad_game', 'message', 'Unknown game.');
  end if;
  if v_label = '' then v_label := p_game_key; end if;

  insert into public.scoreboard_awards (board_id, group_name, points, game_key, label)
  values (a.p_board, p_group, p_points, p_game_key, v_label)
  returning id into v_id;
  perform public._sb_refresh(a.p_board);
  return public._sb_view(a.p_board) || jsonb_build_object('award_id', v_id);
end $$;

-- Undoes one award: p_award_id if given (the toast's Undo button), otherwise
-- the latest award that is not undone yet.
create or replace function public.sb_undo(p_code text, p_pin text, p_award_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record;
  v_id bigint;
begin
  a := public._sb_auth(p_code, p_pin);
  if a.p_board is null then return jsonb_build_object('error', a.p_err, 'message', a.p_msg); end if;
  select id into v_id from public.scoreboard_awards
   where board_id = a.p_board and not undone and (p_award_id is null or id = p_award_id)
   order by id desc limit 1
   for update;
  if v_id is null then return public._sb_view(a.p_board, 'nothing_to_undo'); end if;
  update public.scoreboard_awards set undone = true, undone_at = now() where id = v_id;
  perform public._sb_refresh(a.p_board);
  return public._sb_view(a.p_board) || jsonb_build_object('undone_id', v_id);
end $$;

-- Timer actions:
--   set        load p_seconds, stopped (the TV shows it ready)
--   start      count down from p_seconds, or from the loaded time if p_seconds is null
--   pause      stop and keep the time left
--   resume     carry on from the time left
--   reset      stop and go back to the loaded time
--   add_minute one more minute, running or not
-- p_label, when given, replaces the timer label.
create or replace function public.sb_timer(p_code text, p_pin text, p_action text,
                                           p_seconds int default null, p_label text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a record;
  s public.scoreboard_state;
  v_label text := nullif(left(regexp_replace(trim(coalesce(p_label, '')), '\s+', ' ', 'g'), 40), '');
  v_left numeric;
  v_secs int;
begin
  a := public._sb_auth(p_code, p_pin);
  if a.p_board is null then return jsonb_build_object('error', a.p_err, 'message', a.p_msg); end if;
  if p_seconds is not null and (p_seconds < 1 or p_seconds > 10800) then
    return jsonb_build_object('error', 'bad_seconds', 'message', 'Use between 1 second and 180 minutes.');
  end if;

  select * into s from public.scoreboard_state where id = a.p_board for update;
  v_left := case when s.timer_running
                 then greatest(0, extract(epoch from (s.timer_ends_at - now())))
                 else coalesce(s.timer_remaining_s, s.timer_duration_s) end;

  if p_action = 'set' then
    if p_seconds is null then
      return jsonb_build_object('error', 'bad_seconds', 'message', 'Choose how many minutes first.');
    end if;
    update public.scoreboard_state set timer_duration_s = p_seconds, timer_remaining_s = p_seconds,
           timer_ends_at = null, timer_running = false
     where id = a.p_board;

  elsif p_action = 'start' then
    v_secs := coalesce(p_seconds, s.timer_duration_s);
    if v_secs is null or v_secs < 1 then
      return jsonb_build_object('error', 'bad_seconds', 'message', 'Choose how many minutes first.');
    end if;
    update public.scoreboard_state set timer_duration_s = v_secs, timer_remaining_s = null,
           timer_ends_at = now() + make_interval(secs => v_secs), timer_running = true
     where id = a.p_board;

  elsif p_action = 'pause' then
    if not s.timer_running then return public._sb_view(a.p_board, 'not_running'); end if;
    update public.scoreboard_state set timer_remaining_s = round(v_left, 3), timer_ends_at = null,
           timer_running = false
     where id = a.p_board;

  elsif p_action = 'resume' then
    if s.timer_running then return public._sb_view(a.p_board, 'already_running'); end if;
    if v_left <= 0 then return public._sb_view(a.p_board, 'nothing_to_resume'); end if;
    update public.scoreboard_state set timer_ends_at = now() + make_interval(secs => v_left::double precision),
           timer_remaining_s = null, timer_running = true
     where id = a.p_board;

  elsif p_action = 'reset' then
    update public.scoreboard_state set timer_remaining_s = timer_duration_s, timer_ends_at = null,
           timer_running = false
     where id = a.p_board;

  elsif p_action = 'add_minute' then
    -- A timer that already hit zero gets a fresh minute.
    if s.timer_running then
      update public.scoreboard_state set
             timer_ends_at = greatest(timer_ends_at, now()) + interval '60 seconds',
             timer_duration_s = case when v_left <= 0 then 60 else least(timer_duration_s + 60, 10800) end
       where id = a.p_board;
    else
      update public.scoreboard_state set
             timer_remaining_s = v_left + 60,
             timer_duration_s = case when v_left <= 0 then 60 else least(timer_duration_s + 60, 10800) end
       where id = a.p_board;
    end if;

  else
    return jsonb_build_object('error', 'bad_action', 'message', 'Unknown timer action.');
  end if;

  update public.scoreboard_state set timer_label = coalesce(v_label, timer_label),
         rev = rev + 1, updated_at = now()
   where id = a.p_board;
  return public._sb_view(a.p_board);
end $$;

create or replace function public.sb_segment(p_code text, p_pin text, p_segment text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._sb_auth(p_code, p_pin);
  if a.p_board is null then return jsonb_build_object('error', a.p_err, 'message', a.p_msg); end if;
  if p_segment is null or not (p_segment = any (public._sb_segments())) then
    return jsonb_build_object('error', 'bad_segment', 'message', 'Unknown segment.');
  end if;
  update public.scoreboard_state set segment = p_segment, rev = rev + 1, updated_at = now()
   where id = a.p_board;
  return public._sb_view(a.p_board);
end $$;

-- Deletes every award and sets all totals to 0. The timer and segment stay.
create or replace function public.sb_reset(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._sb_auth(p_code, p_pin);
  if a.p_board is null then return jsonb_build_object('error', a.p_err, 'message', a.p_msg); end if;
  delete from public.scoreboard_awards where board_id = a.p_board;
  perform public._sb_refresh(a.p_board);
  return public._sb_view(a.p_board);
end $$;

-- ---------------------------------------------------------------- execute grants
-- Only the scoreboard's own functions. Never a blanket revoke here: that would
-- also hit the quiz functions.
revoke execute on function
  public._sb_groups(),
  public._sb_segments(),
  public._sb_auth(text, text),
  public._sb_refresh(uuid),
  public._sb_view(uuid, text),
  public.sb_set_keeper_pin(text, text),
  public.sb_server_time(),
  public.sb_keeper_state(text, text),
  public.sb_award(text, text, text, int, text, text),
  public.sb_undo(text, text, bigint),
  public.sb_timer(text, text, text, int, text),
  public.sb_segment(text, text, text),
  public.sb_reset(text, text)
from public, anon, authenticated;

grant execute on function
  public.sb_server_time(),
  public.sb_keeper_state(text, text),
  public.sb_award(text, text, text, int, text, text),
  public.sb_undo(text, text, bigint),
  public.sb_timer(text, text, text, int, text),
  public.sb_segment(text, text, text),
  public.sb_reset(text, text)
to anon, authenticated;

-- ---------------------------------------------------------------- the board
insert into public.scoreboard_state (code, segment) values ('ARCPH', 'Setup')
on conflict (code) do nothing;
insert into public.scoreboard_secrets (board_id)
select id from public.scoreboard_state where code = 'ARCPH'
on conflict (board_id) do nothing;
select public._sb_refresh(id) from public.scoreboard_state where code = 'ARCPH';

-- Check: one row, six groups in totals, and pin_set tells you if the PIN is in.
select b.code, b.totals, b.segment, (s.keeper_pin_hash is not null) as pin_set
from public.scoreboard_state b join public.scoreboard_secrets s on s.board_id = b.id
where b.code = 'ARCPH';

-- Done. Next, in a new query: select public.sb_set_keeper_pin('ARCPH', 'your-keeper-pin');

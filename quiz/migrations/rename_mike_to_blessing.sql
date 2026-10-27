-- Rename the group "Mike" to "Blessing" on an existing database.
-- Run once in the Supabase SQL editor. Safe to run again: it does nothing the second time.
-- Does not touch players' answers, scores, questions or the PIN.

begin;

-- 1. Drop the old group_name check constraints, whatever Postgres named them.
do $$
declare
  r record;
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

-- 2. Move existing rows over before the new constraints go on.
update public.players     set group_name = 'Blessing' where group_name = 'Mike';
update public.card_awards set group_name = 'Blessing' where group_name = 'Mike';

-- 3. Add the constraints back with Blessing.
alter table public.players add constraint players_group_name_check
  check (group_name in ('Bobbilee', 'Sam', 'Tim', 'Rachel', 'Jeremy', 'Blessing'));
alter table public.card_awards add constraint card_awards_group_name_check
  check (group_name in ('Bobbilee', 'Sam', 'Tim', 'Rachel', 'Jeremy', 'Blessing'));

-- 4. The group list used by player_join, host_card_set and the group scores.
create or replace function public._groups()
returns text[] language sql immutable as $$
  select array['Bobbilee', 'Sam', 'Tim', 'Rachel', 'Jeremy', 'Blessing']
$$;

commit;

-- Check: should return the six groups ending in Blessing, and 0 Mike rows.
select public._groups() as groups,
       (select count(*) from public.players     where group_name = 'Mike') as mike_players,
       (select count(*) from public.card_awards where group_name = 'Mike') as mike_cards;

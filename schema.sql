-- Survivor Pools: database schema
-- Paste this whole file into Supabase > SQL Editor and click Run.

create extension if not exists pgcrypto;

-- ---------- Tables ----------

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text not null default '',
  email text not null default '',
  created_at timestamptz not null default now()
);

create table public.pools (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  commissioner_id uuid not null references public.profiles(id) on delete cascade,
  lives int not null default 3 check (lives between 1 and 5),
  max_picks_per_team int not null default 1 check (max_picks_per_team in (1, 2)),
  missed_pick_strike boolean not null default true,
  lock_mode text not null default 'game' check (lock_mode in ('game', 'first')),
  reveal_picks text not null default 'start' check (reveal_picks in ('start', 'always')),
  start_date date not null default current_date,
  created_at timestamptz not null default now()
);

create table public.pool_members (
  pool_id uuid not null references public.pools on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  joined_on date not null default current_date,
  strike_adjust int not null default 0,
  primary key (pool_id, user_id)
);

create table public.invites (
  id uuid primary key default gen_random_uuid(),
  pool_id uuid not null references public.pools on delete cascade,
  email text not null,
  invited_by uuid references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  unique (pool_id, email)
);

-- Saturday NHL games, shared by every pool. Filled by the sync-games function.
create table public.games (
  id bigint primary key,
  game_date date not null,
  start_time timestamptz not null,
  away text not null,
  home text not null,
  away_pct numeric,
  home_pct numeric,
  status text not null default 'scheduled' check (status in ('scheduled', 'live', 'final')),
  away_score int,
  home_score int,
  winner text,
  odds_updated_at timestamptz,
  updated_at timestamptz not null default now()
);
create index games_date_idx on public.games (game_date);

create table public.picks (
  pool_id uuid not null references public.pools on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  game_date date not null,
  team text not null,
  game_id bigint not null references public.games,
  updated_at timestamptz not null default now(),
  primary key (pool_id, user_id, game_date)
);

-- ---------- New users get a profile ----------

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name, email)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), split_part(new.email, '@', 1)),
          lower(new.email))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- Helpers ----------

create or replace function public.is_member(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from pool_members where pool_id = p and user_id = auth.uid())
$$;

create or replace function public.is_commish(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from pools where id = p and commissioner_id = auth.uid())
$$;

create or replace function public.game_locked(p_lock text, g_date date, g_id bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_lock = 'first'
    then exists (select 1 from games where game_date = g_date and (start_time <= now() or status <> 'scheduled'))
    else exists (select 1 from games where id = g_id and (start_time <= now() or status <> 'scheduled'))
  end
$$;

-- One player's record in one pool
create or replace function public.member_record(p uuid, u uuid)
returns table (wins int, losses int, missed int, adjust int, strikes int, lives_left int)
language sql stable security definer set search_path = public as $$
  with po as (select * from pools where id = p),
  m as (select * from pool_members where pool_id = p and user_id = u and is_member(p)),
  res as (
    select count(*) filter (where g.status = 'final' and g.winner = pk.team)::int as w,
           count(*) filter (where g.status = 'final' and g.winner is not null and g.winner <> pk.team)::int as l
    from picks pk join games g on g.id = pk.game_id
    where pk.pool_id = p and pk.user_id = u
  ),
  done as (select game_date from games group by game_date having bool_and(status = 'final')),
  miss as (
    select count(*)::int as c from done d, m, po
    where po.missed_pick_strike
      and d.game_date > m.joined_on
      and d.game_date >= po.start_date
      and not exists (select 1 from picks where pool_id = p and user_id = u and game_date = d.game_date)
  )
  select res.w, res.l, miss.c, m.strike_adjust,
         greatest(0, res.l + miss.c + m.strike_adjust),
         least(po.lives, greatest(0, po.lives - (res.l + miss.c + m.strike_adjust)))
  from res, miss, m, po
$$;

-- ---------- Functions the app calls ----------

create or replace function public.create_pool(p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  insert into pools (name, commissioner_id) values (trim(p_name), auth.uid()) returning id into new_id;
  insert into pool_members (pool_id, user_id) values (new_id, auth.uid());
  return new_id;
end $$;

create or replace function public.my_invites()
returns table (id uuid, pool_id uuid, pool_name text, invited_by_name text)
language sql stable security definer set search_path = public as $$
  select i.id, i.pool_id, p.name, coalesce(pr.display_name, '')
  from invites i
  join pools p on p.id = i.pool_id
  left join profiles pr on pr.id = i.invited_by
  where i.accepted_at is null
    and lower(i.email) = lower(auth.jwt()->>'email')
    and not exists (select 1 from pool_members m where m.pool_id = i.pool_id and m.user_id = auth.uid())
$$;

create or replace function public.accept_invite(p_invite uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare inv invites;
begin
  select * into inv from invites
  where id = p_invite and accepted_at is null and lower(email) = lower(auth.jwt()->>'email');
  if not found then raise exception 'This invite is no longer valid'; end if;
  insert into pool_members (pool_id, user_id) values (inv.pool_id, auth.uid()) on conflict do nothing;
  update invites set accepted_at = now() where id = inv.id;
  return inv.pool_id;
end $$;

create or replace function public.pool_standings(p uuid)
returns table (user_id uuid, display_name text, is_commissioner boolean,
               wins int, losses int, missed int, adjust int, strikes int, lives_left int)
language sql stable security definer set search_path = public as $$
  select pm.user_id, pr.display_name, (po.commissioner_id = pm.user_id),
         r.wins, r.losses, r.missed, r.adjust, r.strikes, r.lives_left
  from pool_members pm
  join profiles pr on pr.id = pm.user_id
  join pools po on po.id = pm.pool_id
  cross join lateral member_record(p, pm.user_id) r
  where pm.pool_id = p and is_member(p)
$$;

-- Everyone's picks, with other players' picks hidden until they lock
create or replace function public.pool_picks(p uuid)
returns table (user_id uuid, game_date date, team text, hidden boolean)
language sql stable security definer set search_path = public as $$
  select pk.user_id, pk.game_date,
         case when v.vis then pk.team end,
         not v.vis
  from picks pk
  join pools po on po.id = pk.pool_id
  cross join lateral (
    select (pk.user_id = auth.uid() or po.reveal_picks = 'always'
            or game_locked(po.lock_mode, pk.game_date, pk.game_id)) as vis
  ) v
  where pk.pool_id = p and is_member(p)
$$;

-- Save or clear (p_team = null) a pick, with every rule checked here
create or replace function public.make_pick(p uuid, g_date date, p_team text) returns void
language plpgsql security definer set search_path = public as $$
declare
  po pools; g games; existing picks; used int; rec record;
begin
  if not is_member(p) then raise exception 'You are not in this pool'; end if;
  select * into po from pools where id = p;
  select * into rec from member_record(p, auth.uid());
  if rec.lives_left <= 0 then raise exception 'You have been eliminated from this pool'; end if;
  if g_date < po.start_date then raise exception 'That Saturday is before this pool started'; end if;

  select * into existing from picks where pool_id = p and user_id = auth.uid() and game_date = g_date;
  if found and game_locked(po.lock_mode, existing.game_date, existing.game_id) then
    raise exception 'Your pick for that Saturday is locked';
  end if;

  if p_team is null then
    delete from picks where pool_id = p and user_id = auth.uid() and game_date = g_date;
    return;
  end if;

  select * into g from games where game_date = g_date and (away = p_team or home = p_team) limit 1;
  if not found then raise exception 'That team is not playing that Saturday'; end if;
  if game_locked(po.lock_mode, g.game_date, g.id) then raise exception 'That game has already started'; end if;

  select count(*) into used from picks
  where pool_id = p and user_id = auth.uid() and team = p_team and game_date <> g_date;
  if used >= po.max_picks_per_team then
    raise exception 'You have already used % the maximum number of times', p_team;
  end if;

  insert into picks (pool_id, user_id, game_date, team, game_id)
  values (p, auth.uid(), g_date, p_team, g.id)
  on conflict (pool_id, user_id, game_date)
  do update set team = excluded.team, game_id = excluded.game_id, updated_at = now();
end $$;

-- Commissioner only: add (+1) or give back (-1) a strike
create or replace function public.adjust_strike(p uuid, u uuid, delta int) returns void
language plpgsql security definer set search_path = public as $$
declare rec record;
begin
  if not is_commish(p) then raise exception 'Only the commissioner can change strikes'; end if;
  if delta not in (-1, 1) then raise exception 'Change strikes one at a time'; end if;
  select * into rec from member_record(p, u);
  if rec is null then raise exception 'That player is not in this pool'; end if;
  if delta = -1 and rec.losses + rec.missed + rec.adjust <= 0 then
    raise exception 'That player has no strikes to give back';
  end if;
  update pool_members set strike_adjust = strike_adjust + delta where pool_id = p and user_id = u;
end $$;

-- Commissioner only: remove a player
create or replace function public.remove_member(p uuid, u uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_commish(p) then raise exception 'Only the commissioner can remove players'; end if;
  if u = auth.uid() then raise exception 'The commissioner can''t be removed'; end if;
  delete from picks where pool_id = p and user_id = u;
  delete from pool_members where pool_id = p and user_id = u;
end $$;

-- ---------- Row-level security ----------

alter table public.profiles enable row level security;
alter table public.pools enable row level security;
alter table public.pool_members enable row level security;
alter table public.invites enable row level security;
alter table public.games enable row level security;
alter table public.picks enable row level security;

create policy "own profile" on public.profiles for select using (id = auth.uid());
create policy "edit own profile" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

create policy "members see pool" on public.pools for select using (is_member(id));
create policy "commissioner edits pool" on public.pools for update
  using (commissioner_id = auth.uid()) with check (commissioner_id = auth.uid());
create policy "commissioner deletes pool" on public.pools for delete using (commissioner_id = auth.uid());

create policy "members see members" on public.pool_members for select using (is_member(pool_id));
create policy "leave pool" on public.pool_members for delete using (user_id = auth.uid() and not is_commish(pool_id));

create policy "see invites" on public.invites for select
  using (is_commish(pool_id) or lower(email) = lower(auth.jwt()->>'email'));
create policy "cancel invites" on public.invites for delete
  using (is_commish(pool_id) or lower(email) = lower(auth.jwt()->>'email'));

create policy "signed-in users see games" on public.games for select to authenticated using (true);

create policy "own picks" on public.picks for select using (user_id = auth.uid());

-- No insert/update policies on purpose: picks, strikes, members and invites
-- change only through the functions above (or the send-invite edge function).

-- Schema Supabase "tessera" (progetto vxxmgymywnjpkbnhfbpx) - generato il 2026-11-18
-- Serve per ricreare il database da zero. Eseguire nello SQL Editor.

create table public.tessera_owners (
  id uuid primary key references auth.users(id),
  email text not null,
  biz_name text not null,
  trade text not null,
  phone text,
  reward text,
  slots integer not null default 10 check (slots >= 3 and slots <= 24),
  theme text not null default 'cobalto',
  status text not null default 'trial' check (status in ('trial','active','suspended')),
  trial_ends_at timestamptz not null default (now() + interval '3 days'),
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  scan_points integer not null default 1 check (scan_points >= 1 and scan_points <= 20)
);

create table public.tessera_clients (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.tessera_owners(id),
  name text not null,
  phone text,
  code text not null unique default ('TS-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8))),
  pts integer not null default 0 check (pts >= 0),
  created_at timestamptz not null default now(),
  secret text not null default (replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','')),
  email text
);

create table public.tessera_codes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.tessera_owners(id),
  code text not null unique,
  created_at timestamptz not null default now(),
  used_at timestamptz
);

create table public.tessera_admins (
  user_id uuid primary key references auth.users(id)
);

create table public.tessera_scans (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.tessera_owners(id),
  client_id uuid not null references public.tessera_clients(id),
  points integer not null,
  kind text not null check (kind in ('scan','manual')),
  created_at timestamptz not null default now()
);

alter table public.tessera_owners  enable row level security;
alter table public.tessera_clients enable row level security;
alter table public.tessera_codes   enable row level security;
alter table public.tessera_admins  enable row level security;
alter table public.tessera_scans   enable row level security;

-- Policy
create policy codes_admin    on public.tessera_codes   for select using (tessera_is_admin());
create policy owners_update  on public.tessera_owners  for update using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy owners_select  on public.tessera_owners  for select using (id = (select auth.uid()) or tessera_is_admin());
create policy clients_delete on public.tessera_clients for delete using (owner_id = (select auth.uid()) and tessera_owner_ok(owner_id));
create policy clients_update on public.tessera_clients for update using (owner_id = (select auth.uid()) and tessera_owner_ok(owner_id)) with check (owner_id = (select auth.uid()) and tessera_owner_ok(owner_id));
create policy clients_insert on public.tessera_clients for insert with check (owner_id = (select auth.uid()) and tessera_owner_ok(owner_id));
create policy clients_select on public.tessera_clients for select using (owner_id = (select auth.uid()) or tessera_is_admin());
create policy scans_select   on public.tessera_scans   for select using (owner_id = (select auth.uid()) or tessera_is_admin());

-- Funzioni
create or replace function public.tessera_is_admin() returns boolean language sql stable security definer set search_path to ''
as $$ select exists(select 1 from public.tessera_admins a where a.user_id = (select auth.uid())) $$;

create or replace function public.tessera_owner_ok(uid uuid) returns boolean language sql stable security definer set search_path to ''
as $$ select exists(select 1 from public.tessera_owners o where o.id = uid and (o.status = 'active' or (o.status = 'trial' and o.trial_ends_at > now()))) $$;

create or replace function public.tessera_add_points(p_code text default null, p_client uuid default null, p_points integer default null, p_kind text default 'scan')
returns json language plpgsql security definer set search_path to ''
as $$
declare
  uid uuid := auth.uid();
  o public.tessera_owners;
  c public.tessera_clients;
  delta integer;
  newpts integer;
begin
  if uid is null then return json_build_object('ok',false,'error','non autenticato'); end if;
  if p_kind not in ('scan','manual') then return json_build_object('ok',false,'error','tipo non valido'); end if;
  select * into o from public.tessera_owners where id = uid;
  if not found or not public.tessera_owner_ok(uid) then return json_build_object('ok',false,'error','abbonamento non attivo'); end if;
  select * into c from public.tessera_clients where owner_id = uid and ((p_client is not null and id = p_client) or (p_client is null and code = upper(trim(p_code)))) for update;
  if not found then return json_build_object('ok',false,'error','cliente non trovato'); end if;
  if p_kind = 'scan' then
    delta := o.scan_points;
    if exists (select 1 from public.tessera_scans s where s.client_id = c.id and s.kind = 'scan' and s.created_at > now() - interval '2 minutes') then
      return json_build_object('ok',false,'error','doppia','name',c.name,'pts',c.pts);
    end if;
  else
    delta := p_points;
    if delta is null or delta = 0 or abs(delta) > 100 then return json_build_object('ok',false,'error','numero non valido'); end if;
  end if;
  newpts := greatest(0, c.pts + delta);
  delta := newpts - c.pts;
  update public.tessera_clients set pts = newpts where id = c.id;
  insert into public.tessera_scans(owner_id, client_id, points, kind) values (uid, c.id, delta, p_kind);
  return json_build_object('ok',true,'name',c.name,'pts',newpts,'added',delta,'kind',p_kind);
end
$$;

create or replace function public.tessera_admin_set(p_owner uuid, p_status text, p_days integer default 0)
returns void language plpgsql security definer set search_path to ''
as $$
begin
  if not public.tessera_is_admin() then raise exception 'non autorizzato'; end if;
  if p_status not in ('trial','active','suspended') then raise exception 'stato non valido'; end if;
  update public.tessera_owners set status = p_status,
    trial_ends_at = case when p_days > 0 then greatest(trial_ends_at, now()) + make_interval(days => p_days) else trial_ends_at end,
    activated_at = case when p_status = 'active' then coalesce(activated_at, now()) else activated_at end
  where id = p_owner;
end $$;

create or replace function public.tessera_make_code(p_owner uuid) returns text language plpgsql security definer set search_path to ''
as $$
declare c text; al text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; i int;
begin
  if not public.tessera_is_admin() then raise exception 'non autorizzato'; end if;
  loop
    c := ''; for i in 1..8 loop c := c || substr(al, 1 + floor(random()*31)::int, 1); end loop;
    c := substr(c,1,4) || '-' || substr(c,5);
    begin insert into public.tessera_codes(owner_id,code) values(p_owner,c); return c;
    exception when unique_violation then null; end;
  end loop;
end $$;

create or replace function public.tessera_new_user() returns trigger language plpgsql security definer set search_path to ''
as $$
declare s int;
begin
  if new.raw_user_meta_data ? 'trade' then
    begin s := (new.raw_user_meta_data->>'slots')::int; exception when others then s := 10; end;
    insert into public.tessera_owners(id,email,biz_name,trade,phone,reward,slots,theme) values(
      new.id, new.email,
      left(coalesce(new.raw_user_meta_data->>'biz_name','Attività'),40),
      left(new.raw_user_meta_data->>'trade',30),
      left(new.raw_user_meta_data->>'phone',30),
      left(new.raw_user_meta_data->>'reward',60),
      least(24, greatest(3, coalesce(s,10))),
      left(coalesce(new.raw_user_meta_data->>'theme','cobalto'),20));
  end if;
  return new;
end $$;

create or replace function public.tessera_redeem(p_code text) returns boolean language plpgsql security definer set search_path to ''
as $$
declare r public.tessera_codes;
begin
  select * into r from public.tessera_codes where owner_id = auth.uid() and used_at is null and code = upper(trim(p_code)) for update;
  if not found then return false; end if;
  update public.tessera_codes set used_at = now() where id = r.id;
  update public.tessera_owners set status = 'active', activated_at = now() where id = auth.uid();
  return true;
end $$;

create or replace function public.tessera_public_card(p_secret text) returns json language sql stable security definer set search_path to ''
as $$
  select json_build_object('name', c.name, 'pts', c.pts, 'code', c.code, 'biz_name', o.biz_name, 'trade', o.trade, 'reward', o.reward, 'slots', o.slots, 'theme', o.theme, 'active', public.tessera_owner_ok(o.id), 'history', (select coalesce(json_agg(h), '[]'::json) from (select s.created_at, s.points, s.kind from public.tessera_scans s where s.client_id = c.id order by s.created_at desc limit 10) h))
  from public.tessera_clients c join public.tessera_owners o on o.id = c.owner_id
  where length(p_secret) >= 32 and c.secret = p_secret
$$;

-- Trigger: crea il titolare alla registrazione
create trigger tessera_on_signup after insert on auth.users for each row execute function public.tessera_new_user();

-- NOTA: i GRANT (execute sulle funzioni, select/insert/update sulle tabelle per authenticated/anon)
-- non sono inclusi qui; vanno verificati se si ricrea il progetto da zero.

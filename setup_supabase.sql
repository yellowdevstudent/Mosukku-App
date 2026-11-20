-- Mosukku: skema Supabase. Tempel seluruhnya di SQL Editor lalu klik Run.
-- Satu tabel generik "docs" (mirip koleksi/dokumen), dijaga aturan RLS.

create table if not exists public.admins(user_id uuid primary key);

create table if not exists public.docs(
  col text not null,                       -- nama koleksi, mis. users, status, chats/lobby/msgs
  id text not null,
  data jsonb not null default '{}'::jsonb,
  owner uuid not null default auth.uid(),
  at bigint not null default 0,            -- waktu dari klien, hanya untuk urutan tampilan
  updated_at timestamptz not null default now(),   -- waktu server: kedaluwarsa status & kuota unggah
  primary key(col,id)
);
create index if not exists docs_col_at on public.docs(col, at desc);
alter table public.docs enable row level security;
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path=public as
$$ select exists(select 1 from public.admins where user_id=auth.uid()) $$;

-- pengaman: pemilik dipaksa = pengguna login, waktu server, kuota 3 unggahan/hari
create or replace function public.docs_guard() returns trigger
language plpgsql security definer set search_path=public as $$
declare n int; d0 timestamptz;
begin
  new.owner := coalesce(auth.uid(), new.owner);
  new.updated_at := now();
  new.at := coalesce((new.data->>'at')::bigint, (extract(epoch from now())*1000)::bigint);
  if (new.data ? 'img' or new.data ? 'file') and (new.col like 'chats/%' or new.col='status') then
    d0 := date_trunc('day', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
    select count(*) into n from public.docs
      where owner=new.owner and updated_at>=d0 and (data ? 'img' or data ? 'file')
        and (col like 'chats/%' or col='status') and not (col=new.col and id=new.id);
    if n>=3 then raise exception 'Batas 3 unggahan per hari tercapai'; end if;
  end if;
  return new;
end $$;
drop trigger if exists docs_guard_t on public.docs;
create trigger docs_guard_t before insert or update on public.docs for each row execute function public.docs_guard();

-- membaca
drop policy if exists docs_read on public.docs;
create policy docs_read on public.docs for select to authenticated using (
  case
    when col in ('users','invites','banners') then true
    when col='status' then updated_at > now() - interval '24 hours'
    when col='rooms' then id='lobby' or position(auth.uid()::text in id)>0
    when col='resp' then id=auth.uid()::text or public.is_admin()
    when col like 'chats/%' then col like 'chats/lobby/%' or position(auth.uid()::text in col)>0
    else false end);

-- menulis (insert + update)
drop policy if exists docs_ins on public.docs;
create policy docs_ins on public.docs for insert to authenticated with check (
  case
    when col in ('users','status','resp') then id=auth.uid()::text
    when col='rooms' then id='lobby' or position(auth.uid()::text in id)>0
    when col in ('invites','banners') then public.is_admin()
    when col like 'chats/%/msgs' then (col like 'chats/lobby/%' or position(auth.uid()::text in col)>0) and data->>'from'=auth.uid()::text
    else false end);
drop policy if exists docs_upd on public.docs;
create policy docs_upd on public.docs for update to authenticated
  using (col in ('users','status','resp','rooms') and (owner=auth.uid() or col='rooms'))
  with check (
  case
    when col in ('users','status','resp') then id=auth.uid()::text
    when col='rooms' then id='lobby' or position(auth.uid()::text in id)>0
    else false end);
-- menghapus: milik sendiri, atau admin
drop policy if exists docs_del on public.docs;
create policy docs_del on public.docs for delete to authenticated using (owner=auth.uid() or public.is_admin());

-- realtime (tanpa replica identity full, agar isi pesan yang dihapus tidak bocor)
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- OPSIONAL: bersihkan status kedaluwarsa tiap jam (aktifkan dulu Database > Extensions > pg_cron)
-- select cron.schedule('hapus-status','0 * * * *',$$delete from public.docs where col='status' and updated_at < now()-interval '24 hours'$$);

-- Выполнить один раз в SQL Editor проекта Supabase.
begin;
create table public.family_wallets (
  id uuid primary key default gen_random_uuid(),
  payload jsonb not null default '{"names":["Муж","Жена"],"initial":0,"tx":[],"debts":[]}'::jsonb,
  revision bigint not null default 0,
  updated_at timestamptz not null default now()
);
create table public.family_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  wallet_id uuid not null references public.family_wallets(id) on delete cascade,
  person smallint not null check (person in (0,1)),
  unique(wallet_id,person)
);
alter table public.family_wallets enable row level security;
alter table public.family_members enable row level security;
revoke all on public.family_wallets, public.family_members from anon, authenticated;
grant select on public.family_wallets, public.family_members to authenticated;
create policy member_self on public.family_members for select to authenticated using (user_id = (select auth.uid()));
create policy wallet_member on public.family_wallets for select to authenticated using (
 exists (select 1 from public.family_members m where m.wallet_id = family_wallets.id and m.user_id = (select auth.uid()))
);
-- Единственный путь записи. Проверка пользователя и версии выполняется в одной транзакции.
create function public.save_family_wallet(p_id uuid,p_revision bigint,p_payload jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare next_revision bigint; item jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.family_members where user_id=auth.uid() and wallet_id=p_id) then
  raise exception 'ACCESS_DENIED' using errcode='42501';
 end if;
 if p_payload is null or octet_length(p_payload::text)>5000000 or
 jsonb_typeof(p_payload) is distinct from 'object' or
 jsonb_typeof(p_payload->'names') is distinct from 'array' or
 jsonb_typeof(p_payload->'initial') is distinct from 'number' or
 jsonb_typeof(p_payload->'tx') is distinct from 'array' or
 jsonb_typeof(p_payload->'debts') is distinct from 'array' then raise exception 'INVALID_DATA'; end if;
 if jsonb_array_length(p_payload->'names')<>2 then raise exception 'INVALID_NAMES'; end if;
 for item in select value from jsonb_array_elements(p_payload->'names') loop
  if jsonb_typeof(item)<>'string' or length(item#>>'{}') not between 1 and 40 then raise exception 'INVALID_NAMES'; end if;
 end loop;
 for item in select value from jsonb_array_elements((p_payload->'tx') || (p_payload->'debts')) loop
  if jsonb_typeof(item) is distinct from 'object' or jsonb_typeof(item->'id') is distinct from 'string'
    or jsonb_typeof(item->'amount') is distinct from 'number' or (item->>'amount')::numeric<=0
    or item->>'person' is null or item->>'person' not in ('0','1') then raise exception 'INVALID_RECORD'; end if;
 end loop;
 if (select count(*) from jsonb_array_elements((p_payload->'tx') || (p_payload->'debts'))) <>
    (select count(distinct value->>'id') from jsonb_array_elements((p_payload->'tx') || (p_payload->'debts'))) then raise exception 'DUPLICATE_ID'; end if;
 for item in select value from jsonb_array_elements(p_payload->'debts') loop
  if item->>'type' is null or item->>'type' not in ('borrowed','lent','credit','installment') or jsonb_typeof(item->'name') is distinct from 'string' then raise exception 'INVALID_DEBT'; end if;
  if (select coalesce(sum((value->>'amount')::numeric),0) from jsonb_array_elements(p_payload->'tx') where value->>'debtId'=item->>'id')>(item->>'amount')::numeric then raise exception 'OVERPAYMENT'; end if;
 end loop;
 for item in select value from jsonb_array_elements(p_payload->'tx') loop
  if item->>'type' is null or item->>'type' not in ('expense','income','pay','receive','borrow','lend')
   or jsonb_typeof(item->'category') is distinct from 'string' or jsonb_typeof(item->'note') is distinct from 'string'
   or item->>'date' is null or (item->>'date') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'INVALID_TRANSACTION'; end if;
  if item ? 'debtId' and not exists(select 1 from jsonb_array_elements(p_payload->'debts') d where d->>'id'=item->>'debtId') then raise exception 'MISSING_DEBT'; end if;
 end loop;
 update public.family_wallets set payload=p_payload,revision=revision+1,updated_at=now()
 where id=p_id and revision=p_revision returning revision into next_revision;
 if next_revision is null then raise exception 'CONFLICT' using errcode='40001'; end if;
 return next_revision;
end $$;
revoke all on function public.save_family_wallet(uuid,bigint,jsonb) from public,anon;
grant execute on function public.save_family_wallet(uuid,bigint,jsonb) to authenticated;
commit;

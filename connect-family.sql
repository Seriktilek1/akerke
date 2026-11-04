-- Сначала создайте ДВА аккаунта в Authentication → Users → Add user.
-- Замените адреса ниже на их почту и выполните этот файл ОДИН раз.
do $$
declare husband uuid; wife uuid; family uuid;
begin
 select id into husband from auth.users where lower(email)=lower('YOUR_EMAIL@example.com');
 select id into wife from auth.users where lower(email)=lower('WIFE_EMAIL@example.com');
 if husband is null or wife is null or husband=wife then raise exception 'Укажите два разных существующих аккаунта'; end if;
 if exists(select 1 from public.family_members where user_id in(husband,wife)) then raise exception 'Один из аккаунтов уже подключён. Данные не изменены.'; end if;
 insert into public.family_wallets default values returning id into family;
 insert into public.family_members(user_id,wallet_id,person) values(husband,family,0),(wife,family,1);
end $$;

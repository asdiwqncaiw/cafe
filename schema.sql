-- Учёт кофейни и кухни. Версия 6.4.
-- Вставить целиком в Supabase -> SQL Editor -> New query -> Run.
-- Можно запускать повторно: данные не пропадут, ничего не задвоится.
--
-- Что нового в v4:
--   * роль "dev" (разработчики Илья и Арсен) с Dev-панелью;
--   * цеха у товаров (zone): bar / kitchen / cups и подсказка по фасовке (pack_info);
--   * настройки в app_settings (токен бота, chat id, секрет для GitHub Actions);
--   * отправка сводки в Telegram прямо из базы (pg_net): токен бота не попадает на телефоны;
--   * функция ping() для GitHub Actions;
--   * Realtime: Гарик видит изменения сразу, без обновления страницы.
--
-- Что нового в v6.2–6.4:
--   * вечерняя сводка в 23:00 запускается внутри базы (pg_cron -> cron_evening_auto), секрет не нужен;
--     старая cron_evening_report(p_secret) удалена;
--   * app_state(): все данные для экранов одним запросом;
--   * правила доступа считают auth.uid() один раз на запрос, у shifts одно правило на чтение;
--   * индексы на report_items.user_id и shifts.user_id.

-- ============ РАСШИРЕНИЯ ============
-- pg_net позволяет базе самой делать HTTP-запросы (в Telegram). Есть в бесплатном тарифе.
create extension if not exists pg_net with schema extensions;
-- pg_cron запускает вечернюю сводку по расписанию. Тоже есть в бесплатном тарифе.
create extension if not exists pg_cron;

-- ============ ТАБЛИЦЫ ============

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null default 'pending'
    check (role in ('pending','worker','admin','owner','dev','blocked')),
  created_at timestamptz not null default now()
);
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('pending','worker','admin','owner','dev','blocked'));

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  unit text not null default 'шт',
  qty numeric not null default 0 check (qty >= 0),
  min_qty numeric not null default 0 check (min_qty >= 0),
  expires_on date,
  created_at timestamptz not null default now()
);
-- Цех: bar = кофе, молоко, сиропы, спортпит; cups = крышки, стаканы, расходники; kitchen = выпечка, кондитерка, обеды
alter table public.products add column if not exists zone text not null default 'bar';
-- Подсказка по фасовке, например "1 кор = 10 пачек по 50 шт"
alter table public.products add column if not exists pack_info text;
-- track = true: считаем остаток числом (кофе, молоко, стаканы, крышки) и следим за минимумом.
-- track = false: число не ведём, только отмечаем «закончилось» (сиропы, салфетки, ложки, заморозка).
alter table public.products add column if not exists track boolean not null default true;
-- Сколько дней едет заказ. По нему считается «скоро закончится».
alter table public.products add column if not exists lead_days int not null default 4;
alter table public.products drop constraint if exists products_zone_check;
alter table public.products add constraint products_zone_check check (zone in ('bar','cups','kitchen'));
create index if not exists products_zone_idx on public.products (zone);

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  user_id uuid,
  user_name text,
  action text not null,
  product_name text,
  old_qty numeric,
  new_qty numeric,
  note text
);
create index if not exists audit_log_at_idx on public.audit_log (at desc);

create table if not exists public.shifts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  start_time time not null,
  end_time time not null,
  note text
);
create index if not exists shifts_day_idx on public.shifts (day);
create index if not exists shifts_user_id_idx on public.shifts (user_id);

create table if not exists public.report_items (
  id uuid primary key default gen_random_uuid(),
  day date not null,
  kind text not null check (kind in ('writeoff','lunch')),
  name text not null,
  qty numeric,
  note text,
  user_id uuid references public.profiles(id) on delete set null,
  user_name text,
  created_at timestamptz not null default now()
);
alter table public.report_items add column if not exists updated_at timestamptz not null default now();
create index if not exists report_items_day_idx on public.report_items (day);
create index if not exists report_items_user_id_idx on public.report_items (user_id);

create table if not exists public.need_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status text not null default 'out' check (status in ('out','low')),
  note text,
  created_by text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by text
);
create index if not exists need_items_open_idx on public.need_items (resolved_at);

create table if not exists public.day_reports (
  day date primary key,
  submitted_at timestamptz not null default now(),
  submitted_by text
);

-- Технические настройки. Читать и менять их можно только через функции ниже (только роль dev).
create table if not exists public.app_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);
insert into public.app_settings (key, value) values
  ('tg_bot_token', ''), ('tg_chat_id', ''), ('cron_secret', ''), ('tz', 'Europe/Moscow')
on conflict (key) do nothing;

-- ============ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ============

create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role(), '') in ('worker','admin','owner','dev')
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role(), '') in ('admin','owner','dev')
$$;

create or replace function public.is_dev()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role(), '') = 'dev'
$$;

create or replace function public.role_ru(r text)
returns text language sql immutable as $$
  select case r
    when 'pending' then 'ждёт подтверждения'
    when 'worker'  then 'работник'
    when 'admin'   then 'админ'
    when 'owner'   then 'владелец'
    when 'dev'     then 'разработчик'
    when 'blocked' then 'заблокирован'
    else r end
$$;

create or replace function public.zone_ru(z text)
returns text language sql immutable as $$
  select case z
    when 'bar'     then 'Кофейня и Бар'
    when 'kitchen' then 'Кухня и Выпечка'
    when 'cups'    then 'Стаканы и Расходники'
    else coalesce(z, '') end
$$;

create or replace function public.setting(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from public.app_settings where key = p_key
$$;

-- Часовой пояс кафе. Нужен, чтобы "сегодня" в базе совпадало с "сегодня" на телефоне.
create or replace function public.cafe_tz()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim((select value from public.app_settings where key = 'tz')), ''), 'Europe/Moscow')
$$;

create or replace function public.cafe_today()
returns date language sql stable security definer set search_path = public as $$
  select (now() at time zone public.cafe_tz())::date
$$;

-- Проверка доступа. p_level: 'staff' (все сотрудники), 'admin' (админ, владелец, разработчик), 'dev'.
create or replace function public.require_role(p_level text, p_msg text default 'Нет доступа')
returns public.profiles language plpgsql stable security definer set search_path = public as $$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found
     or (p_level = 'staff' and me.role not in ('worker','admin','owner','dev'))
     or (p_level = 'admin' and me.role not in ('admin','owner','dev'))
     or (p_level = 'dev'   and me.role <> 'dev') then
    raise exception '%', p_msg;
  end if;
  return me;
end $$;

-- Работник может вносить отчёт только за последние 3 дня, админы за любую дату.
create or replace function public.check_day(p_me public.profiles, p_day date)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if p_day is null then raise exception 'Не указана дата'; end if;
  if p_me.role = 'worker' and (p_day < public.cafe_today() - 3 or p_day > public.cafe_today() + 1) then
    raise exception 'Для этой даты отчёт закрыт, обратитесь к админу';
  end if;
end $$;

-- ============ НОВЫЙ ПОЛЬЗОВАТЕЛЬ ============
-- Самый первый зарегистрированный становится владельцем.
-- Все остальные ждут, пока админ их подтвердит.

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, role)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)),
    case when exists (select 1 from public.profiles) then 'pending' else 'owner' end
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============ ПРАВА ДОСТУПА (RLS) ============
-- auth.uid() и проверки ролей обёрнуты в (select ...): Postgres считает их один раз на запрос, а не на каждую строку.

alter table public.profiles     enable row level security;
alter table public.products     enable row level security;
alter table public.audit_log    enable row level security;
alter table public.shifts       enable row level security;
alter table public.report_items enable row level security;
alter table public.need_items   enable row level security;
alter table public.day_reports  enable row level security;
alter table public.app_settings enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists products_select on public.products;
create policy products_select on public.products for select to authenticated
  using (public.is_staff());

drop policy if exists log_select on public.audit_log;
create policy log_select on public.audit_log for select to authenticated
  using ((select public.is_admin()) or ((select public.my_role()) = 'worker' and user_id = (select auth.uid())));

drop policy if exists shifts_select on public.shifts;
create policy shifts_select on public.shifts for select to authenticated
  using ((select public.is_admin()) or ((select public.my_role()) = 'worker' and user_id = (select auth.uid())));

-- запись разнесена по действиям, чтобы на чтение было одно правило, а не два
drop policy if exists shifts_write on public.shifts;
drop policy if exists shifts_insert on public.shifts;
drop policy if exists shifts_update on public.shifts;
drop policy if exists shifts_delete on public.shifts;
create policy shifts_insert on public.shifts for insert to authenticated with check ((select public.is_admin()));
create policy shifts_update on public.shifts for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy shifts_delete on public.shifts for delete to authenticated using ((select public.is_admin()));

drop policy if exists report_select on public.report_items;
create policy report_select on public.report_items for select to authenticated
  using (public.is_staff());

drop policy if exists need_select on public.need_items;
create policy need_select on public.need_items for select to authenticated
  using (public.is_staff());

drop policy if exists day_reports_select on public.day_reports;
create policy day_reports_select on public.day_reports for select to authenticated
  using (public.is_staff());

-- У app_settings политик нет специально: напрямую таблицу не прочитать никому.

-- Остатки, журнал, отчёты и роли меняются только через функции ниже,
-- напрямую в эти таблицы писать нельзя. Поэтому журнал не обойти.

-- ============ ОСТАТКИ И ТОВАРЫ ============

create or replace function public.change_stock(
  p_product uuid, p_kind text, p_amount numeric,
  p_reason text default null, p_expires date default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.products;
  newq numeric;
begin
  me := public.require_role('staff');
  if p_amount is null or p_amount < 0 or (p_amount = 0 and p_kind <> 'set') then
    raise exception 'Введите количество больше нуля';
  end if;

  select * into r from public.products where id = p_product for update;
  if not found then raise exception 'Продукт не найден'; end if;

  if p_kind = 'restock' then
    newq := r.qty + p_amount;
  elsif p_kind = 'writeoff' then
    newq := r.qty - p_amount;
    if newq < 0 then raise exception 'Нельзя списать больше, чем есть (сейчас %)', trim_scale(r.qty); end if;
  elsif p_kind = 'set' then
    newq := p_amount;
  else
    raise exception 'Неизвестное действие';
  end if;

  update public.products
     set qty = newq,
         expires_on = case when p_kind = 'restock' and p_expires is not null then p_expires else expires_on end
   where id = r.id;

  insert into public.audit_log (user_id, user_name, action, product_name, old_qty, new_qty, note)
  values (me.id, me.name, p_kind, r.name, r.qty, newq,
          nullif(trim(coalesce(p_reason, '')), ''));
end $$;

-- Старые версии без цеха, фасовки и признака учёта больше не нужны.
drop function if exists public.save_product(uuid, text, text, numeric, numeric, date);
drop function if exists public.save_product(uuid, text, text, numeric, numeric, date, text, text);
drop function if exists public.save_product(uuid, text, text, numeric, numeric, date, text, text, boolean);

create or replace function public.save_product(
  p_id uuid, p_name text, p_unit text, p_min numeric, p_qty numeric, p_expires date,
  p_zone text default 'bar', p_pack text default null, p_track boolean default true, p_lead int default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.products;
  z  text;
  pk text;
  tr boolean := coalesce(p_track, true);
begin
  me := public.require_role('admin', 'Только админ может менять список продуктов');
  if p_name is null or trim(p_name) = '' then raise exception 'Введите название'; end if;
  z  := case when p_zone in ('bar','cups','kitchen') then p_zone else 'bar' end;
  pk := nullif(left(trim(coalesce(p_pack, '')), 120), '');

  if p_id is null then
    insert into public.products (name, unit, qty, min_qty, expires_on, zone, pack_info, track, lead_days)
    values (trim(p_name), coalesce(nullif(trim(p_unit), ''), 'шт'), case when tr then coalesce(p_qty, 0) else 0 end,
            case when tr then coalesce(p_min, 0) else 0 end, p_expires, z, pk, tr, greatest(coalesce(p_lead, 4), 0));
    insert into public.audit_log (user_id, user_name, action, product_name, new_qty, note)
    values (me.id, me.name, 'add_product', trim(p_name), coalesce(p_qty, 0), public.zone_ru(z));
  else
    select * into r from public.products where id = p_id for update;
    if not found then raise exception 'Продукт не найден'; end if;
    update public.products
       set name = trim(p_name), unit = coalesce(nullif(trim(p_unit), ''), 'шт'),
           min_qty = case when tr then coalesce(p_min, 0) else 0 end,
           expires_on = p_expires, zone = z, pack_info = pk, track = tr,
           lead_days = greatest(coalesce(p_lead, lead_days), 0)
     where id = p_id;
    insert into public.audit_log (user_id, user_name, action, product_name, note)
    values (me.id, me.name, 'edit_product', trim(p_name),
            'было: ' || r.name || ', ' || r.unit || ', минимум ' || trim_scale(r.min_qty)::text
            || ', срок ' || coalesce(to_char(r.expires_on, 'DD.MM.YYYY'), 'нет')
            || ', ' || public.zone_ru(r.zone)
            || coalesce(', фасовка: ' || r.pack_info, ''));
  end if;
end $$;

create or replace function public.delete_product(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.products;
begin
  me := public.require_role('admin', 'Только админ может удалять продукты');
  select * into r from public.products where id = p_id for update;
  if not found then raise exception 'Продукт не найден'; end if;
  delete from public.products where id = p_id;
  insert into public.audit_log (user_id, user_name, action, product_name, old_qty)
  values (me.id, me.name, 'delete_product', r.name, r.qty);
end $$;

-- Импорт списка товаров (Dev-панель). Совпадение по названию без учёта регистра:
-- существующий товар обновляется, новый добавляется. Пустые поля не трогают старые значения.
-- p_items: [{"name":"Крышки 400","unit":"кор","min":1,"qty":3,"zone":"cups","pack":"1 кор = 10 пачек по 50 шт"}]
create or replace function public.import_products(p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  it jsonb;
  nm text; u text; mn numeric; q numeric; z text; pk text; tr boolean;
  r  public.products;
  added int := 0;
  updated int := 0;
begin
  me := public.require_role('admin');
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'Слишком много строк за раз (максимум 500)';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    nm := left(nullif(trim(it->>'name'), ''), 120);
    continue when nm is null;
    u  := nullif(left(trim(coalesce(it->>'unit', '')), 10), '');
    mn := case when jsonb_typeof(it->'min') = 'number' and (it->>'min')::numeric >= 0 then (it->>'min')::numeric end;
    q  := case when jsonb_typeof(it->'qty') = 'number' and (it->>'qty')::numeric >= 0 then (it->>'qty')::numeric end;
    z  := case when it->>'zone' in ('bar','cups','kitchen') then it->>'zone' end;
    pk := nullif(left(trim(coalesce(it->>'pack', '')), 120), '');
    tr := case when jsonb_typeof(it->'track') = 'boolean' then (it->>'track')::boolean end;

    select * into r from public.products where lower(name) = lower(nm) order by created_at limit 1 for update;
    if found then
      update public.products
         set unit = coalesce(u, unit), min_qty = coalesce(mn, min_qty), qty = coalesce(q, qty),
             zone = coalesce(z, zone), pack_info = coalesce(pk, pack_info), track = coalesce(tr, track)
       where id = r.id;
      if q is not null and q <> r.qty then
        insert into public.audit_log (user_id, user_name, action, product_name, old_qty, new_qty, note)
        values (me.id, me.name, 'set', r.name, r.qty, q, 'импорт списка');
      end if;
      updated := updated + 1;
    else
      insert into public.products (name, unit, qty, min_qty, zone, pack_info, track)
      values (nm, coalesce(u, 'шт'), coalesce(q, 0), coalesce(mn, 0), coalesce(z, 'bar'), pk, coalesce(tr, true));
      added := added + 1;
    end if;
  end loop;

  if added + updated = 0 then raise exception 'Нечего импортировать'; end if;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'import', 'новых: ' || added || ', обновлено: ' || updated);
  return jsonb_build_object('added', added, 'updated', updated);
end $$;

-- ============ РОЛИ ============
-- Админ принимает и блокирует работников.
-- Админов и владельцев назначает владелец или разработчик.
-- Разработчиков назначают и меняют только разработчики.

create or replace function public.set_role(p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  t  public.profiles;
begin
  me := public.require_role('admin');
  if p_role not in ('pending','worker','admin','owner','dev','blocked') then
    raise exception 'Неверная роль';
  end if;
  select * into t from public.profiles where id = p_user;
  if not found then raise exception 'Пользователь не найден'; end if;
  if t.id = me.id then raise exception 'Свою роль менять нельзя'; end if;
  if (t.role = 'dev' or p_role = 'dev') and me.role <> 'dev' then
    raise exception 'Разработчиков меняют только разработчики';
  end if;
  if me.role = 'admin' and (t.role in ('admin','owner') or p_role in ('admin','owner')) then
    raise exception 'Админов и владельцев назначает только владелец';
  end if;

  update public.profiles set role = p_role where id = p_user;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'role',
          t.name || ': ' || public.role_ru(t.role) || ' → ' || public.role_ru(p_role));
end $$;

-- ============ ЖУРНАЛ СМЕН ============

create or replace function public.log_shift()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  s public.shifts;
  act text;
  wname text;
  me_name text;
begin
  if tg_op = 'DELETE' then
    s := old; act := 'shift_del';
  else
    s := new;
    act := case when tg_op = 'INSERT' then 'shift_add' else 'shift_edit' end;
  end if;
  select name into wname   from public.profiles where id = s.user_id;
  select name into me_name from public.profiles where id = auth.uid();
  insert into public.audit_log (user_id, user_name, action, note)
  values (auth.uid(), coalesce(me_name, '?'), act,
          coalesce(wname, '?') || ': ' || to_char(s.day, 'DD.MM') || ' '
          || to_char(s.start_time, 'HH24:MI') || '-' || to_char(s.end_time, 'HH24:MI'));
  return null;
end $$;

drop trigger if exists shifts_log on public.shifts;
create trigger shifts_log
  after insert or update or delete on public.shifts
  for each row execute function public.log_shift();

-- ============ ДНЕВНОЙ ОТЧЁТ: СПИСАНИЯ И ОБЕДЫ ============

-- Добавить записи списком. p_items: [{"name":"запеканка","qty":2,"note":""}]
-- Одна строка на день, раздел и название: списания складываются, обеды заменяются.
create or replace function public.add_report_items(p_day date, p_kind text, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.report_items;
  it jsonb;
  nm text;
  q numeric;
  summary text := '';
  n int := 0;
begin
  me := public.require_role('staff');
  if p_kind not in ('writeoff','lunch') then raise exception 'Неверный раздел'; end if;
  perform public.check_day(me, p_day);
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 60 then
    raise exception 'Слишком много строк за раз';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    nm := left(nullif(trim(it->>'name'), ''), 120);
    continue when nm is null;
    q := case when jsonb_typeof(it->'qty') = 'number' then (it->>'qty')::numeric else null end;
    select * into r from public.report_items
     where day = p_day and kind = p_kind and lower(name) = lower(nm)
     order by created_at limit 1 for update;
    if found then
      update public.report_items
         set qty = case when p_kind = 'writeoff' then coalesce(r.qty, 0) + coalesce(q, 0) else coalesce(q, r.qty) end,
             user_id = me.id, user_name = me.name, updated_at = now(),
             note = coalesce(nullif(left(trim(coalesce(it->>'note', '')), 200), ''), r.note)
       where id = r.id;
    else
      insert into public.report_items (day, kind, name, qty, note, user_id, user_name)
      values (p_day, p_kind, nm, q, nullif(left(trim(coalesce(it->>'note', '')), 200), ''), me.id, me.name);
    end if;
    summary := summary || case when n > 0 then ', ' else '' end
               || coalesce(trim_scale(q)::text || ' ', '') || nm;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Нечего добавлять'; end if;

  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'report_add',
          to_char(p_day, 'DD.MM') || ' ' || case p_kind when 'writeoff' then 'списания' else 'обеды' end
          || ': ' || left(summary, 300));
end $$;

create or replace function public.edit_report_item(p_id uuid, p_name text, p_qty numeric, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.report_items;
begin
  me := public.require_role('staff');
  select * into r from public.report_items where id = p_id for update;
  if not found then raise exception 'Запись не найдена'; end if;
  if me.role = 'worker' and r.day < public.cafe_today() - 3 then
    raise exception 'Эту запись уже нельзя менять, обратитесь к админу';
  end if;
  if p_name is null or trim(p_name) = '' then raise exception 'Введите название'; end if;

  update public.report_items
     set name = left(trim(p_name), 120), qty = p_qty, updated_at = now(),
         note = nullif(left(trim(coalesce(p_note, '')), 200), '')
   where id = p_id;

  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'report_edit',
          to_char(r.day, 'DD.MM') || ': ' || coalesce(trim_scale(r.qty)::text || ' ', '') || r.name
          || ' → ' || coalesce(trim_scale(p_qty)::text || ' ', '') || left(trim(p_name), 120));
end $$;

create or replace function public.delete_report_item(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.report_items;
begin
  me := public.require_role('staff');
  select * into r from public.report_items where id = p_id for update;
  if not found then raise exception 'Запись не найдена'; end if;
  if me.role = 'worker' and r.day < public.cafe_today() - 3 then
    raise exception 'Эту запись уже нельзя удалить, обратитесь к админу';
  end if;
  delete from public.report_items where id = p_id;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'report_del',
          to_char(r.day, 'DD.MM') || ' ' || case r.kind when 'writeoff' then 'списания' else 'обеды' end
          || ': ' || coalesce(trim_scale(r.qty)::text || ' ', '') || r.name);
end $$;

-- Старый быстрый счётчик. Приложение v4 его не вызывает, оставлен для совместимости.
create or replace function public.bump_report_item(p_day date, p_kind text, p_name text, p_delta numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000 then raise exception 'Неверное количество'; end if;
  perform public.change_report_item(p_day, p_kind, p_name, p_delta, false);
end $$;

-- +1 / -1 / задать число для позиции отчёта. Одна строка на день, раздел и название.
-- Списания: меняется на дельту, при нуле строка исчезает. Обеды: p_set = true задаёт число.
create or replace function public.change_report_item(
  p_day date, p_kind text, p_name text, p_delta numeric, p_set boolean default false)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.report_items;
  nm text;
  newq numeric;
  kind_ru text;
  what text;
begin
  me := public.require_role('staff');
  if p_kind not in ('writeoff','lunch') then raise exception 'Неверный раздел'; end if;
  if p_delta is null then raise exception 'Неверные данные'; end if;
  perform public.check_day(me, p_day);
  nm := left(trim(coalesce(p_name, '')), 120);
  if nm = '' then raise exception 'Введите название'; end if;
  kind_ru := case p_kind when 'writeoff' then 'списания' else 'обеды' end;

  select * into r from public.report_items
   where day = p_day and kind = p_kind and lower(name) = lower(nm)
   order by created_at limit 1 for update;

  if not found then
    newq := greatest(p_delta, 0);
    if p_kind = 'writeoff' and newq <= 0 then return 0; end if;
    insert into public.report_items (day, kind, name, qty, user_id, user_name)
    values (p_day, p_kind, nm, newq, me.id, me.name);
  else
    newq := greatest(case when p_set then p_delta else coalesce(r.qty, 0) + p_delta end, 0);
    if p_kind = 'writeoff' and newq <= 0 then
      delete from public.report_items where id = r.id;
    else
      update public.report_items
         set qty = newq, user_id = me.id, user_name = me.name, updated_at = now()
       where id = r.id;
    end if;
  end if;

  what := case
    when p_set then '= ' || trim_scale(newq)::text
    when p_delta >= 0 then '+' || trim_scale(p_delta)::text || ' (всего ' || trim_scale(newq)::text || ')'
    else trim_scale(p_delta)::text || ' (всего ' || trim_scale(newq)::text || ')' end;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'report_add', to_char(p_day, 'DD.MM') || ' ' || kind_ru || ': ' || nm || ' ' || what);
  return newq;
end $$;

-- ============ СПИСОК "ЗАКОНЧИЛОСЬ / ЗАКАНЧИВАЕТСЯ" ============
-- Висит, пока кто-то не нажмёт "Привезли".
-- p_items: [{"name":"крышки большие","status":"out","note":""}]

create or replace function public.add_needs(p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  it jsonb;
  nm text;
  st text;
  nt text;
  summary text := '';
  n int := 0;
begin
  me := public.require_role('staff');
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 60 then
    raise exception 'Слишком много строк за раз';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    nm := nullif(trim(it->>'name'), '');
    continue when nm is null;
    nm := left(nm, 120);
    st := case when it->>'status' = 'low' then 'low' else 'out' end;
    nt := nullif(left(trim(coalesce(it->>'note', '')), 200), '');
    if exists (select 1 from public.need_items where resolved_at is null and lower(name) = lower(nm)) then
      update public.need_items
         set status = st, note = coalesce(nt, note)
       where resolved_at is null and lower(name) = lower(nm);
    else
      insert into public.need_items (name, status, note, created_by) values (nm, st, nt, me.name);
    end if;
    summary := summary || case when n > 0 then ', ' else '' end || nm
               || ' (' || case st when 'low' then 'заканчивается' else 'закончилось' end || ')';
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Нечего добавлять'; end if;

  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'need_add', left(summary, 300));
end $$;

create or replace function public.set_need(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.need_items;
begin
  me := public.require_role('staff');
  if p_status not in ('out','low') then raise exception 'Неверный статус'; end if;
  select * into r from public.need_items where id = p_id and resolved_at is null for update;
  if not found then return; end if;  -- кто-то уже отметил «привезли», ничего не делаем
  if r.status = p_status then return; end if;
  update public.need_items set status = p_status where id = p_id;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'need_edit',
          r.name || ': ' || case p_status when 'low' then 'заканчивается' else 'закончилось' end);
end $$;

create or replace function public.resolve_need(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.need_items;
begin
  me := public.require_role('staff');
  select * into r from public.need_items where id = p_id and resolved_at is null for update;
  if not found then return; end if;  -- двое нажали «привезли» одновременно: засчитываем один раз
  update public.need_items set resolved_at = now(), resolved_by = me.name where id = p_id;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'need_done', r.name);
end $$;

create or replace function public.delete_need(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.need_items;
begin
  me := public.require_role('staff');
  select * into r from public.need_items where id = p_id for update;
  if not found then return; end if;
  delete from public.need_items where id = p_id;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'need_del', r.name);
end $$;


-- ============ «СКОРО ЗАКОНЧИТСЯ» И «ПРИВЕЗЛИ» ============

-- Считаемые товары, которых хватит на срок доставки (lead_days) или меньше.
-- Скорость расхода берётся из журнала: списания и уменьшения при пересчёте за последние p_days дней.
create or replace function public.product_soon(p_days int default 14)
returns table(id uuid, name text, qty numeric, unit text, per_day numeric, days_left numeric, lead_days int)
language sql stable security definer set search_path = public as $$
  with u as (
    select lower(product_name) as k,
           sum(greatest(old_qty - new_qty, 0)) as used,
           greatest(1, least(p_days, extract(epoch from now() - min(at)) / 86400.0)) as span
      from public.audit_log
     where at > now() - make_interval(days => p_days)
       and action in ('writeoff', 'set') and old_qty is not null and new_qty is not null
     group by 1)
  select p.id, p.name, p.qty, p.unit,
         round((u.used / u.span)::numeric, 2),
         round((p.qty / (u.used / u.span))::numeric, 1),
         p.lead_days
    from public.products p join u on u.k = lower(p.name)
   where public.is_staff() and p.track and u.used > 0 and p.qty > 0
     and not (p.min_qty > 0 and p.qty <= p.min_qty)
     and p.qty / (u.used / u.span) <= p.lead_days + 1
   order by 6
$$;

-- «Привезли»: для считаемого товара прибавляет количество, и снимает отметку «заканчивается / закончилось».
create or replace function public.arrived(p_name text, p_amount numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  p  public.products;
  nm text := trim(coalesce(p_name, ''));
begin
  me := public.require_role('staff');
  if nm = '' then raise exception 'Не указан товар'; end if;
  if p_amount is not null and p_amount < 0 then raise exception 'Количество не может быть меньше нуля'; end if;
  select * into p from public.products where lower(name) = lower(nm) order by created_at limit 1 for update;
  if found and p.track and coalesce(p_amount, 0) > 0 then
    update public.products set qty = qty + p_amount where id = p.id;
    insert into public.audit_log (user_id, user_name, action, product_name, old_qty, new_qty, note)
    values (me.id, me.name, 'restock', p.name, p.qty, p.qty + p_amount, 'привезли');
  end if;
  update public.need_items set resolved_at = now(), resolved_by = me.name
   where resolved_at is null and lower(name) = lower(nm);
  if found then
    insert into public.audit_log (user_id, user_name, action, note) values (me.id, me.name, 'need_done', nm);
  end if;
end $$;

-- ============ ВСЁ ДЛЯ ЭКРАНОВ ОДНИМ ЗАПРОСОМ ============
-- Приложение вызывает app_state вместо десяти отдельных запросов.

create or replace function public.app_state(p_day date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me public.profiles;
  adm boolean;
  res jsonb;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found then return jsonb_build_object('me', null); end if;
  if me.role not in ('worker','admin','owner','dev') then return jsonb_build_object('me', to_jsonb(me)); end if;
  adm := me.role in ('admin','owner','dev');

  select jsonb_build_object(
    'me', to_jsonb(me),
    'products', coalesce((select jsonb_agg(to_jsonb(p) order by p.name) from public.products p), '[]'),
    'logs', coalesce((select jsonb_agg(to_jsonb(l) order by l.at desc) from (
        select * from public.audit_log
         where adm or user_id = me.id
         order by at desc limit 200) l), '[]'),
    'report', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from public.report_items r where r.day = p_day), '[]'),
    'needs', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at) from public.need_items n where n.resolved_at is null), '[]'),
    'day_reports', coalesce((select jsonb_agg(to_jsonb(d)) from public.day_reports d where d.day >= public.cafe_today() - 21), '[]'),
    'soon', coalesce((select jsonb_agg(to_jsonb(s)) from public.product_soon(14) s), '[]'),
    'names', jsonb_build_object(
      'writeoff', coalesce((select jsonb_agg(name order by c desc, name) from (
          select min(trim(name)) as name, count(*) c from public.report_items
           where kind = 'writeoff' and day >= public.cafe_today() - 45 group by lower(trim(name)) order by c desc limit 14) x), '[]'),
      'lunch', coalesce((select jsonb_agg(name order by c desc, name) from (
          select min(trim(name)) as name, count(*) c from public.report_items
           where kind = 'lunch' and day >= public.cafe_today() - 45 group by lower(trim(name)) order by c desc limit 14) x), '[]'),
      'need', coalesce((select jsonb_agg(name order by c desc, name) from (
          select min(trim(name)) as name, count(*) c from public.need_items
           group by lower(trim(name)) order by c desc limit 14) x), '[]')),
    'people', case when adm then coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at) from public.profiles p), '[]') else '[]' end,
    'week', case when adm then coalesce((select jsonb_agg(jsonb_build_object('kind', r.kind, 'name', r.name, 'qty', r.qty, 'day', r.day, 'user_name', r.user_name))
        from public.report_items r where r.day >= public.cafe_today() - 6), '[]') else '[]' end
  ) into res;
  return res;
end $$;

-- ============ TELEGRAM ============
-- Сводку собирает и отправляет сама база через pg_net.
-- Токен бота лежит в app_settings и никогда не уходит на телефоны.

create or replace function public.tg_esc(t text)
returns text language sql immutable as $$
  select replace(replace(replace(t, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

create or replace function public.tg_report_text(p_day date)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  tz text := public.cafe_tz();
  dr public.day_reports;
  r record;
  wd text := (array['воскресенье','понедельник','вторник','среда','четверг','пятница','суббота'])[extract(dow from p_day)::int + 1];
  urgent text := '';
  low text := '';
  wo text := '';
  lu text := '';
  soon text := '';
  t text;
  t2 text;
begin
  select * into dr from public.day_reports where day = p_day;

  t := '📊 <b>Отчёт за ' || to_char(p_day, 'DD.MM.YYYY') || '</b>, ' || wd || E'\n';
  if dr.day is not null then
    t := t || '✅ Сдал(а): <b>' || coalesce(public.tg_esc(dr.submitted_by), '?') || '</b> в '
           || to_char(dr.submitted_at at time zone tz, 'HH24:MI');
  else
    t := t || '⏳ Отчёт не сдан, сводка собрана автоматически';
  end if;

  -- Срочно, сначала критичное: считаемые товары (крышки, стаканы, кофе, молоко),
  -- которые отметили «закончилось» или которых не больше минимума.
  for r in select n.name, n.note from public.need_items n
            where n.resolved_at is null and n.status = 'out'
              and exists (select 1 from public.products p where p.track and lower(p.name) = lower(n.name))
            order by n.created_at loop
    urgent := urgent || E'\n‼️ <b>' || public.tg_esc(r.name) || '</b>: закончилось'
              || coalesce(' <i>(' || public.tg_esc(r.note) || ')</i>', '');
  end loop;
  for r in select p.name, p.qty, p.min_qty, p.unit, p.pack_info from public.products p
            where p.track and (p.qty <= 0 or (p.min_qty > 0 and p.qty <= p.min_qty))
              and not exists (select 1 from public.need_items n
                               where n.resolved_at is null and lower(n.name) = lower(p.name))
            order by (p.qty <= 0) desc, case p.zone when 'cups' then 1 when 'bar' then 2 else 3 end, p.name loop
    -- 0 на складе — это «закончилось», а не «осталось 0»
    urgent := urgent || E'\n‼️ <b>' || public.tg_esc(r.name) || '</b>: '
              || case when r.qty <= 0 then 'ЗАКОНЧИЛОСЬ'
                      else 'осталось ' || trim_scale(r.qty)::text || ' ' || public.tg_esc(r.unit)
                           || ' (мин. ' || trim_scale(r.min_qty)::text || ')' end
              || coalesce(' <i>' || public.tg_esc(r.pack_info) || '</i>', '');
  end loop;
  -- Потом всё остальное, что закончилось (сиропы, расходники): без чисел, только названия.
  t2 := '';
  for r in select n.name, n.note from public.need_items n
            where n.resolved_at is null and n.status = 'out'
              and not exists (select 1 from public.products p where p.track and lower(p.name) = lower(n.name))
            order by n.name loop
    t2 := t2 || E'\n• ' || public.tg_esc(r.name)
          || coalesce(' <i>(' || public.tg_esc(r.note) || ')</i>', '');
  end loop;
  if t2 <> '' then
    urgent := urgent || case when urgent = '' then '' else E'\n' end || E'\n<i>Тоже закончилось:</i>' || t2;
  end if;

  for r in select name, note from public.need_items
            where resolved_at is null and status = 'low' order by created_at loop
    low := low || E'\n• ' || public.tg_esc(r.name)
           || coalesce(' <i>(' || public.tg_esc(r.note) || ')</i>', '');
  end loop;

  for r in select * from public.product_soon(14) loop
    soon := soon || E'\n• ' || public.tg_esc(r.name) || ': ' || trim_scale(r.qty)::text || ' ' || public.tg_esc(r.unit)
            || ', хватит примерно на ' || greatest(1, floor(r.days_left))::text || ' дн. (заказ едет ' || r.lead_days || ' дн.)';
  end loop;

  for r in select name, qty, note from public.report_items
            where day = p_day and kind = 'writeoff' order by lower(name) loop
    wo := wo || E'\n• ' || public.tg_esc(r.name) || coalesce(' — ' || trim_scale(r.qty)::text, '')
          || coalesce(' <i>(' || public.tg_esc(r.note) || ')</i>', '');
  end loop;

  for r in select name, qty, note from public.report_items
            where day = p_day and kind = 'lunch' order by lower(name) loop
    lu := lu || E'\n• ' || public.tg_esc(r.name) || coalesce(' — ' || trim_scale(r.qty)::text, '')
          || coalesce(' <i>(' || public.tg_esc(r.note) || ')</i>', '');
  end loop;

  t := t
    || E'\n\n🚨 <b>СРОЧНО ЗАКАЗАТЬ</b>' || case when urgent = '' then E'\nвсё есть' else urgent end
    || E'\n\n⚠️ <b>Заказать заранее (заканчивается)</b>' || case when low = '' then E'\nнет' else low end
    || case when soon = '' then '' else E'\n\n⏳ <b>Скоро закончится</b>' || soon end
    || E'\n\n📉 <b>Списания</b>'        || case when wo = ''     then E'\nнет'      else wo end
    || E'\n\n🍲 <b>Обеды</b>'           || case when lu = ''     then E'\nнет'      else lu end;
  return t;
end $$;

-- Поставить сообщение в очередь pg_net. Возвращает номер запроса или null, если бот не настроен.
create or replace function public.tg_send(p_text text)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare
  tok  text := trim(coalesce(public.setting('tg_bot_token'), ''));
  chat text := trim(coalesce(public.setting('tg_chat_id'), ''));
  msg  text := coalesce(p_text, '');
begin
  if tok = '' or chat = '' then return null; end if;
  if length(msg) > 4000 then msg := left(msg, 3990) || E'\n…'; end if;
  return net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', chat, 'text', msg, 'parse_mode', 'HTML', 'disable_web_page_preview', true),
    headers := '{"Content-Type":"application/json"}'::jsonb,
    timeout_milliseconds := 10000
  );
end $$;

-- Отправить сводку за день. Любая ошибка Telegram не мешает сдать отчёт.
create or replace function public.tg_send_report(p_day date)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if trim(coalesce(public.setting('tg_bot_token'), '')) = '' or trim(coalesce(public.setting('tg_chat_id'), '')) = '' then
    return false;
  end if;
  perform public.tg_send(public.tg_report_text(p_day));
  return true;
exception when others then
  return false;
end $$;

-- ============ СДАТЬ / ОТКРЫТЬ ОТЧЁТ ============

-- Раньше функция ничего не возвращала, теперь возвращает "ушло ли в Telegram".
drop function if exists public.submit_report(date);
create function public.submit_report(p_day date)
returns boolean language plpgsql security definer set search_path = public as $$
declare me public.profiles;
begin
  me := public.require_role('staff');
  perform public.check_day(me, p_day);
  insert into public.day_reports (day, submitted_at, submitted_by) values (p_day, now(), me.name)
  on conflict (day) do update set submitted_at = now(), submitted_by = me.name;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'report_submit', to_char(p_day, 'DD.MM') || ' отчёт сдан');
  return public.tg_send_report(p_day);
end $$;

create or replace function public.reopen_report(p_day date)
returns void language plpgsql security definer set search_path = public as $$
declare me public.profiles;
begin
  me := public.require_role('staff');
  perform public.check_day(me, p_day);
  delete from public.day_reports where day = p_day;
  insert into public.audit_log (user_id, user_name, action, note)
  values (me.id, me.name, 'report_reopen', to_char(p_day, 'DD.MM') || ' отчёт открыт снова');
end $$;

-- ============ DEV-ПАНЕЛЬ (только роль dev) ============

create or replace function public.get_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare tok text;
begin
  perform public.require_role('dev');
  tok := trim(coalesce(public.setting('tg_bot_token'), ''));
  return jsonb_build_object(
    'token_set',   tok <> '',
    'token_mask',  case when tok = '' then '' else '…' || right(tok, 4) end,
    'chat_id',     coalesce(public.setting('tg_chat_id'), ''),
    'cron_secret', coalesce(public.setting('cron_secret'), ''),
    'tz',          public.cafe_tz(),
    'today',       public.cafe_today()
  );
end $$;

create or replace function public.set_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
declare v text := trim(coalesce(p_value, ''));
begin
  perform public.require_role('dev');
  if p_key not in ('tg_bot_token','tg_chat_id','cron_secret','tz') then
    raise exception 'Неизвестная настройка';
  end if;
  if p_key = 'tz' and v <> '' then
    begin
      perform now() at time zone v;
    exception when others then
      raise exception 'Неизвестный часовой пояс: %', v;
    end;
  end if;
  insert into public.app_settings (key, value, updated_at) values (p_key, v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

create or replace function public.tg_test()
returns bigint language plpgsql security definer set search_path = public as $$
declare me public.profiles; id bigint;
begin
  me := public.require_role('dev');
  id := public.tg_send('✅ Бот «Склад кафе» подключён. Проверку отправил(а): ' || coalesce(public.tg_esc(me.name), '?'));
  if id is null then raise exception 'Сначала сохраните токен бота и chat id'; end if;
  return id;
end $$;

create or replace function public.tg_send_now(p_day date default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare id bigint;
begin
  perform public.require_role('dev');
  id := public.tg_send(public.tg_report_text(coalesce(p_day, public.cafe_today())));
  if id is null then raise exception 'Сначала сохраните токен бота и chat id'; end if;
  return id;
end $$;

-- Последние ответы Telegram (pg_net хранит их около 6 часов). Для диагностики.
create or replace function public.tg_last_result()
returns jsonb language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  perform public.require_role('dev');
  begin
    execute $q$
      select coalesce(jsonb_agg(x order by x.id desc), '[]'::jsonb) from (
        select id, status_code, timed_out, error_msg, left(content::text, 300) as content,
               to_char(created at time zone public.cafe_tz(), 'DD.MM HH24:MI:SS') as at
          from net._http_response order by id desc limit 3) x
    $q$ into res;
  exception when others then
    res := jsonb_build_object('error', sqlerrm);
  end;
  return res;
end $$;

-- ============ АВТОМАТИКА ============

-- Пинг раз в сутки из GitHub Actions, чтобы бесплатный проект не уснул. Ничего не раскрывает.
create or replace function public.ping()
returns text language sql stable security definer set search_path = public as $$
  select 'ok ' || to_char(now() at time zone public.cafe_tz(), 'DD.MM.YYYY HH24:MI')
$$;

-- Вечерняя сводка: если отчёт за сегодня не сдан, отправляет Гарику то, что есть.
-- Запускает pg_cron внутри базы, снаружи не вызывается. Старая версия с секретом для GitHub больше не нужна.
drop function if exists public.cron_evening_report(text);
create or replace function public.cron_evening_auto()
returns text language plpgsql security definer set search_path = public as $$
declare d date := public.cafe_today();
begin
  if exists (select 1 from public.day_reports where day = d) then return 'отчёт уже сдан'; end if;
  if not public.tg_send_report(d) then return 'Telegram не настроен'; end if;
  insert into public.audit_log (user_name, action, note)
  values ('робот', 'tg_auto', to_char(d, 'DD.MM') || ': отчёт не сдан, сводка отправлена автоматически');
  return 'сводка отправлена';
end $$;

-- 20:00 UTC = 23:00 по Москве. Повторный запуск обновляет задачу, а не создаёт вторую.
select cron.schedule('cafe-evening-report', '0 20 * * *', 'select public.cron_evening_auto()');

-- ============ ПРАВА НА ТАБЛИЦЫ И ФУНКЦИИ ============

grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.products, public.audit_log,
                public.report_items, public.need_items, public.day_reports to authenticated;
grant select, insert, update, delete on public.shifts to authenticated;
revoke all on public.app_settings from anon, authenticated;

do $$
declare
  f text;
  -- вызывает приложение (только вошедшие сотрудники)
  app_fns text[] := array[
    'public.my_role()', 'public.is_staff()', 'public.is_admin()', 'public.is_dev()',
    'public.cafe_tz()', 'public.cafe_today()', 'public.app_state(date)',
    'public.change_stock(uuid, text, numeric, text, date)',
    'public.save_product(uuid, text, text, numeric, numeric, date, text, text, boolean, integer)',
    'public.product_soon(integer)', 'public.arrived(text, numeric)',
    'public.delete_product(uuid)',
    'public.import_products(jsonb)',
    'public.set_role(uuid, text)',
    'public.add_report_items(date, text, jsonb)',
    'public.edit_report_item(uuid, text, numeric, text)',
    'public.delete_report_item(uuid)',
    'public.bump_report_item(date, text, text, numeric)',
    'public.change_report_item(date, text, text, numeric, boolean)',
    'public.add_needs(jsonb)', 'public.set_need(uuid, text)',
    'public.resolve_need(uuid)', 'public.delete_need(uuid)',
    'public.submit_report(date)', 'public.reopen_report(date)',
    'public.get_settings()', 'public.set_setting(text, text)',
    'public.tg_test()', 'public.tg_send_now(date)', 'public.tg_last_result()'
  ];
  -- только внутри базы, снаружи вызвать нельзя
  inner_fns text[] := array[
    'public.setting(text)', 'public.require_role(text, text)', 'public.check_day(public.profiles, date)',
    'public.tg_report_text(date)', 'public.tg_send(text)', 'public.tg_send_report(date)',
    'public.handle_new_user()', 'public.log_shift()', 'public.cron_evening_auto()'
  ];
  -- для GitHub Actions (вызывается с публичным ключом)
  cron_fns text[] := array['public.ping()'];
begin
  foreach f in array app_fns loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array inner_fns loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array cron_fns loop
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;

-- ============ REALTIME ============
-- Изменения в этих таблицах сразу прилетают на открытые телефоны (с учётом прав RLS).

do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['products','report_items','need_items','day_reports','shifts'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ============ РОЛИ ПО ЛОГИНАМ ============
-- Логин в приложении превращается в почту вида login@cafe-staff.app.
-- Срабатывает только для уже зарегистрированных аккаунтов. Если логины другие, поправьте их здесь.

update public.profiles p set role = 'dev'
  from auth.users u
 where u.id = p.id and split_part(lower(u.email), '@', 1) in ('ilya', 'arsen')
   and p.role <> 'dev';

update public.profiles p set role = 'owner'
  from auth.users u
 where u.id = p.id and split_part(lower(u.email), '@', 1) = 'garik'
   and p.role in ('pending', 'worker', 'admin');

update public.profiles p set role = 'admin'
  from auth.users u
 where u.id = p.id and split_part(lower(u.email), '@', 1) = 'tatyana'
   and p.role in ('pending', 'worker');

-- ============ ЦЕХА ДЛЯ УЖЕ ЗАВЕДЁННЫХ ТОВАРОВ (один раз) ============
-- Раскладывает старые товары по цехам по ключевым словам. Потом цех меняется вручную в карточке товара.

do $$
begin
  if not exists (select 1 from public.app_settings where key = 'zones_autofilled') then
    update public.products set zone = 'cups'
     where zone = 'bar'
       and name ~* '(крышк|стакан|пакет|салфет|трубоч|размешив|перчат|контейнер|упаковк|ланч.?бокс|вилк|ложк|фольг|плёнк|пленк|держател|подстакан|мусор|губк|моющ|бумаг)';
    update public.products set zone = 'kitchen'
     where zone = 'bar'
       and name ~* '(торт|чизкейк|запеканк|борщ|суп|винегрет|салат|макарон|греч|пицц|булоч|булк|круассан|выпеч|сырник|пирож|десерт|эклер|блин|кекс|маффин|печень|котлет|пюре|оладь|тесто|хачапур|сэндвич|бутерброд|омлет|яйц|творог|сметан|мука|мясо|курин|овощ|фарш|^рис| рис)';
    insert into public.app_settings (key, value) values ('zones_autofilled', '1')
    on conflict (key) do nothing;
  end if;
end $$;

-- ============ ПЕРЕХОД НА v6 (один раз) ============
-- Сиропы без «1883:», сиропы считаем бутылками, обычное молоко и сливки отмечаем «Есть / Мало / Нет»,
-- из кухни пока только пончики.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'migr_v6') then
    update public.products set name = regexp_replace(name, '^Сироп\s+(1883|Bonvida)\s*:\s*', 'Сироп ', 'i')
     where name ~* '^Сироп\s+(1883|Bonvida)\s*:';
    update public.need_items set name = regexp_replace(name, '^Сироп\s+(1883|Bonvida)\s*:\s*', 'Сироп ', 'i')
     where name ~* '^Сироп\s+(1883|Bonvida)\s*:';
    update public.products set track = true, unit = 'бут', min_qty = greatest(min_qty, 1)
     where name ~* '^Сироп ' and not track;
    update public.products set track = false, min_qty = 0
     where name in ('Молоко 3,2%', 'Молоко 2,5%', 'Сливки', 'Сливки 10%');
    update public.products set lead_days = 7 where name ~* '^(молоко|сливки)';
    delete from public.products where name in ('Булочки и слойки замороженные', 'Круассаны замороженные');
    if exists (select 1 from public.products where lower(name) = 'пончики') then
      delete from public.products where name = 'Донаты замороженные';
    else
      update public.products set name = 'Пончики', pack_info = null, unit = 'шт' where name = 'Донаты замороженные';
    end if;
    insert into public.products (name, unit, zone, track, qty, min_qty)
    select 'Пончики', 'шт', 'kitchen', false, 0, 0
     where not exists (select 1 from public.products where lower(name) = 'пончики');
    insert into public.app_settings (key, value) values ('migr_v6', '1') on conflict (key) do nothing;
  end if;
end $$;

-- ============ ПЕРЕХОД НА v7 (один раз) ============
-- Молоко 3,2% и 2,5% считаем коробками; растительное — поштучно (как было).
-- Чёрные стаканы убраны: крафтовые и есть чёрные. «1883» убираем из названий ещё раз, на всякий случай.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'migr_v7') then
    update public.products set name = regexp_replace(name, '^Сироп\s+(1883|Bonvida)\s*:?\s*', 'Сироп ', 'i')
     where name ~* '^Сироп\s+(1883|Bonvida)';
    update public.need_items set name = regexp_replace(name, '^Сироп\s+(1883|Bonvida)\s*:?\s*', 'Сироп ', 'i')
     where name ~* '^Сироп\s+(1883|Bonvida)';
    update public.products set track = true, unit = 'кор', min_qty = greatest(min_qty, 1), lead_days = 7, pack_info = null
     where name in ('Молоко 3,2%', 'Молоко 2,5%');
    delete from public.products where name ~* '^Стаканы ч[её]рные';
    update public.need_items set resolved_at = now(), resolved_by = 'обновление'
     where resolved_at is null and name ~* '^Стаканы ч[её]рные';
    insert into public.app_settings (key, value) values ('migr_v7', '1') on conflict (key) do nothing;
  end if;
end $$;

-- Проверка: должно показать 0 сиропов с «1883» и молоко коробками
select (select count(*) from public.products where name ~ '1883') as "сиропов с 1883",
       (select string_agg(name || ' — ' || unit, ', ') from public.products where name in ('Молоко 3,2%','Молоко 2,5%')) as "молоко",
       (select count(*) from public.products where name ~* '^Стаканы ч[её]рные') as "чёрных стаканов";

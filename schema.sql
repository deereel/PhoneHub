-- ============================================================
-- PhoneHub Pro — Supabase Schema (Phase 2, multi-tenant)
-- ============================================================
-- Run this whole file once in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- Safe to re-run top-to-bottom on a fresh project.
-- ============================================================

-- Needed for gen_random_uuid()
create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- 1. DEALERS  (one row per registered seller, linked to their auth account)
-- ------------------------------------------------------------
create table if not exists dealers (
  id uuid primary key references auth.users(id) on delete cascade,
  shop_name text not null,
  shop_slug text unique not null,        -- used in the customer app's shareable link, e.g. /shop/musa-electronics
  phone text,
  whatsapp text,
  location text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

alter table dealers enable row level security;

-- Security-definer helper: checks admin status while bypassing dealers' own RLS,
-- so policies that need to check "is this caller an admin?" don't recursively
-- re-trigger the dealers table's RLS (which would otherwise infinite-loop).
create or replace function is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select d.is_admin from dealers d where d.id = auth.uid()), false);
$$;

-- Dealers can see & edit their own profile row.
create policy "dealers_select_own" on dealers for select
  using (id = auth.uid());
create policy "dealers_update_own" on dealers for update
  using (id = auth.uid());

-- Admins (you) can see every dealer's profile.
create policy "dealers_select_admin" on dealers for select
  using (is_admin());

-- Auto-create a dealer profile row whenever someone signs up.
-- Expects shop_name / phone / shop_slug passed in as auth signup metadata.
create or replace function handle_new_dealer()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into dealers (id, shop_name, shop_slug, phone, location)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'shop_name', 'New Shop'),
    coalesce(new.raw_user_meta_data->>'shop_slug', 'shop-' || substr(new.id::text, 1, 8)),
    new.raw_user_meta_data->>'phone',
    new.raw_user_meta_data->>'location'
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_dealer();

-- Public, read-only directory so the Customer App can resolve a shop_slug to a dealer
-- without exposing anything private. Runs as the (trusted) view owner, so it works
-- even though the requester (a customer) isn't logged in.
create or replace view public_shops
  with (security_invoker = false) as
  select id, shop_name, shop_slug, location from dealers;
grant select on public_shops to anon, authenticated;

-- ------------------------------------------------------------
-- 2. INVENTORY
-- ------------------------------------------------------------
create table if not exists inventory (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references dealers(id) on delete cascade,
  imei text,
  imei2 text,
  model text not null,
  storage text,
  color text,
  condition text check (condition in ('New','Used')),
  battery int,
  supplier text,
  purchase_date date,
  cost numeric,
  price numeric,
  status text not null default 'In Stock' check (status in ('In Stock','Reserved','Sold','In Repair')),
  quantity int not null default 1,
  shelf text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_inventory_dealer on inventory(dealer_id);
create index if not exists idx_inventory_model on inventory using gin (to_tsvector('simple', model));

alter table inventory enable row level security;

create policy "inventory_all_own" on inventory for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());

create policy "inventory_select_admin" on inventory for select
  using (is_admin());

-- Cross-dealer search, for logged-in dealers only. Deliberately excludes cost/supplier
-- so no dealer can see another dealer's margins — only what a buyer needs to know.
create or replace view dealer_network_view
  with (security_invoker = false) as
  select
    i.id, i.dealer_id, d.shop_name as dealer_name, d.phone as dealer_phone,
    i.model, i.storage, i.color, i.condition, i.battery, i.price, i.updated_at
  from inventory i
  join dealers d on d.id = i.dealer_id
  where i.status = 'In Stock';
grant select on dealer_network_view to authenticated;

-- Public storefront catalog for the Customer App (one dealer's in-stock phones only,
-- no cost/supplier/IMEI exposed).
create or replace view public_catalog
  with (security_invoker = false) as
  select id, dealer_id, model, storage, color, condition, battery, price, status
  from inventory
  where status = 'In Stock';
grant select on public_catalog to anon, authenticated;

-- ------------------------------------------------------------
-- 3. SALES
-- ------------------------------------------------------------
create table if not exists sales (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references dealers(id) on delete cascade,
  date date not null default current_date,
  imei text,
  model text,
  cost numeric,
  sale_price numeric,
  customer_name text,
  customer_phone text,
  payment_method text,
  staff text,
  warranty_days int default 0,
  quantity int not null default 1,
  accessories text,
  notes text,
  created_at timestamptz not null default now()
);
create index if not exists idx_sales_dealer on sales(dealer_id);
create index if not exists idx_sales_customer_phone on sales(customer_phone);

alter table sales enable row level security;

create policy "sales_all_own" on sales for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());

create policy "sales_select_admin" on sales for select
  using (is_admin());

-- Lets a customer look up THEIR OWN purchase/warranty history by phone number,
-- without exposing anyone else's sales. Only the fields they need, nothing private.
create or replace function lookup_my_purchases(p_phone text)
returns table (model text, date date, sale_price numeric, warranty_days int, shop_name text)
language sql
security definer set search_path = public
as $$
  select s.model, s.date, s.sale_price, s.warranty_days, d.shop_name
  from sales s join dealers d on d.id = s.dealer_id
  where regexp_replace(s.customer_phone, '\s', '', 'g') = regexp_replace(p_phone, '\s', '', 'g');
$$;
grant execute on function lookup_my_purchases(text) to anon, authenticated;

-- Records a sale and marks the phone Sold, atomically, for the CURRENT dealer only.
-- Runs with the caller's own privileges (not security definer), so normal RLS
-- still applies — a dealer can only ever sell their own in-stock phones.
-- Matches by inventory id (not IMEI) since IMEI is optional and multiple
-- IMEI-less phones would otherwise be indistinguishable.
drop function if exists sell_phone(uuid,numeric,text,text,text,text,int,text,text);

create or replace function sell_phone(
  p_inventory_id uuid, p_sale_price numeric, p_customer_name text, p_customer_phone text,
  p_payment_method text, p_staff text, p_warranty_days int, p_accessories text, p_notes text,
  p_imei text default null, p_quantity int default 1
)
returns sales
language plpgsql
as $$
declare
  v_phone inventory%rowtype;
  v_sale sales%rowtype;
  v_remaining int;
begin
  select * into v_phone from inventory
    where id = p_inventory_id and dealer_id = auth.uid() and status = 'In Stock'
    limit 1;

  if v_phone.id is null then
    raise exception 'No in-stock phone found for that selection';
  end if;

  if p_quantity is null or p_quantity < 1 then
    p_quantity := 1;
  end if;

  if v_phone.quantity < p_quantity then
    raise exception 'Only % in stock — cannot sell %', v_phone.quantity, p_quantity;
  end if;

  insert into sales (dealer_id, imei, model, cost, sale_price, customer_name, customer_phone,
                      payment_method, staff, warranty_days, accessories, notes, quantity)
  values (auth.uid(), coalesce(p_imei, v_phone.imei), v_phone.model, v_phone.cost, p_sale_price, p_customer_name, p_customer_phone,
          p_payment_method, p_staff, p_warranty_days, p_accessories, p_notes, p_quantity)
  returning * into v_sale;

  v_remaining := v_phone.quantity - p_quantity;

  update inventory
    set quantity = v_remaining,
        status = case when v_remaining <= 0 then 'Sold' else 'In Stock' end,
        updated_at = now()
    where id = v_phone.id;

  return v_sale;
end;
$$;
grant execute on function sell_phone(uuid,numeric,text,text,text,text,int,text,text,text,int) to authenticated;

-- ------------------------------------------------------------
-- 4. REQUESTS  (customer waiting-list asks, submitted from the Customer App)
-- ------------------------------------------------------------
create table if not exists requests (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references dealers(id) on delete cascade,
  date date not null default current_date,
  customer_name text,
  customer_phone text,
  model text not null,
  storage text,
  color text,
  budget numeric,
  status text not null default 'Pending' check (status in ('Pending','Fulfilled','Cancelled')),
  notes text,
  created_at timestamptz not null default now()
);
create index if not exists idx_requests_dealer on requests(dealer_id);

alter table requests enable row level security;

-- Anyone (a customer, not logged in) can submit a request to a specific shop.
create policy "requests_insert_anyone" on requests for insert
  with check (true);

-- Only the shop it was sent to (or an admin) can read/manage it.
create policy "requests_select_own" on requests for select
  using (dealer_id = auth.uid());
create policy "requests_update_own" on requests for update
  using (dealer_id = auth.uid());
create policy "requests_select_admin" on requests for select
  using (is_admin());

-- ------------------------------------------------------------
-- 5. SUPPLIERS  (each dealer's own private colleague/supplier contacts)
-- ------------------------------------------------------------
create table if not exists suppliers (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references dealers(id) on delete cascade,
  name text not null,
  phone text,
  whatsapp text,
  location text,
  supplies text,
  notes text,
  owed numeric default 0,
  due date,
  created_at timestamptz not null default now()
);
alter table suppliers enable row level security;
create policy "suppliers_all_own" on suppliers for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());
create policy "suppliers_select_admin" on suppliers for select
  using (is_admin());

-- ------------------------------------------------------------
-- 6. BROADCASTS + RESPONSES  (network-wide "need this phone urgently")
-- ------------------------------------------------------------
create table if not exists broadcasts (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references dealers(id) on delete cascade,   -- who's asking
  date date not null default current_date,
  model text not null,
  storage text,
  color text,
  urgency text,
  status text not null default 'Open' check (status in ('Open','Closed')),
  created_at timestamptz not null default now()
);
alter table broadcasts enable row level security;

-- Every registered dealer can see every open broadcast — that's the point of the network.
create policy "broadcasts_select_all" on broadcasts for select
  using (auth.uid() is not null);
create policy "broadcasts_insert_own" on broadcasts for insert
  with check (dealer_id = auth.uid());
create policy "broadcasts_update_own" on broadcasts for update
  using (dealer_id = auth.uid());

create table if not exists broadcast_responses (
  id uuid primary key default gen_random_uuid(),
  broadcast_id uuid not null references broadcasts(id) on delete cascade,
  dealer_id uuid not null references dealers(id) on delete cascade,   -- who's responding
  price numeric,
  quantity int default 1,
  contact_phone text,
  created_at timestamptz not null default now()
);
alter table broadcast_responses enable row level security;

create policy "broadcast_responses_select_all" on broadcast_responses for select
  using (auth.uid() is not null);
create policy "broadcast_responses_insert_own" on broadcast_responses for insert
  with check (dealer_id = auth.uid());

-- ============================================================
-- After running this file:
-- 1. Sign up your own account through the Seller App (this creates your dealer row).
-- 2. Run:  update dealers set is_admin = true where shop_slug = 'your-shop-slug';
--    (or `where id = 'your-auth-user-id'` — find it in Authentication > Users)
-- ============================================================

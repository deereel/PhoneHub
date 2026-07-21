-- ============================================================
-- PhoneHub Pro — Supabase Schema (Phase 2, multi-tenant)
-- Includes: broadcast visibility scoping (private broadcasts to
-- saved contacts) + dealer-linked contacts (no phone-matching needed)
-- ============================================================
-- Run this whole file once in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- Safe to re-run top-to-bottom on a fresh project, and safe to re-run on an
-- existing project that already has the base schema — every statement below
-- uses IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS.
-- ============================================================

-- Needed for gen_random_uuid()
create extension if not exists "pgcrypto";
create extension if not exists pg_net;

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
drop policy if exists "dealers_select_own" on dealers;
create policy "dealers_select_own" on dealers for select
  using (id = auth.uid());
drop policy if exists "dealers_update_own" on dealers;
create policy "dealers_update_own" on dealers for update
  using (id = auth.uid());

-- Admins (you) can see every dealer's profile.
drop policy if exists "dealers_select_admin" on dealers;
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
-- without exposing anything private. Also doubles as the source list for the
-- "suggest registered dealers while typing a contact name" picker in the Seller App.
create or replace view public_shops
  with (security_invoker = false) as
  select id, shop_name, shop_slug, location, phone from dealers;
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
  status text not null default 'In Stock' check (status in ('In Stock','Reserved','Sold','In Repair','Consigned')),
  quantity int not null default 1,
  shelf text,
  notes text,
  image_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table inventory add column if not exists image_url text;

-- Multi-image support: image_urls holds every photo for a phone (in display
-- order); image_url is kept in sync as the first photo, for any older code
-- path that still reads the single-image column.
alter table inventory add column if not exists image_urls jsonb not null default '[]'::jsonb;
update inventory set image_urls = jsonb_build_array(image_url)
  where image_url is not null and jsonb_array_length(image_urls) = 0;

-- Laptop support: inventory now holds both phones and laptops, distinguished
-- by item_type. Laptops reuse the shared fields above (model, color, condition,
-- battery, cost, price, status, quantity, shelf, notes, photos, supplier, IMEI
-- left blank) plus a few laptop-only spec columns below. Keeping laptops in the
-- same table means they automatically flow through sales, the dealer network,
-- broadcasts, consignments ("Owed to you"), and the Customer App catalog —
-- nothing else needs a parallel table.
alter table inventory add column if not exists item_type text not null default 'Phone';
alter table inventory drop constraint if exists inventory_item_type_check;
alter table inventory add constraint inventory_item_type_check check (item_type in ('Phone','Laptop'));
alter table inventory add column if not exists brand text;       -- laptop brand, e.g. HP, Dell, Apple
alter table inventory add column if not exists cpu text;         -- e.g. Intel Core i7-1165G7
alter table inventory add column if not exists ram text;         -- e.g. 16GB
alter table inventory add column if not exists screen_size text; -- e.g. 15.6"
alter table inventory add column if not exists gpu text;         -- optional, e.g. RTX 3050

create index if not exists idx_inventory_dealer on inventory(dealer_id);
create index if not exists idx_inventory_item_type on inventory(item_type);
create index if not exists idx_inventory_model on inventory using gin (to_tsvector('simple', model));

alter table inventory enable row level security;

drop policy if exists "inventory_all_own" on inventory;
create policy "inventory_all_own" on inventory for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());

drop policy if exists "inventory_select_admin" on inventory;
create policy "inventory_select_admin" on inventory for select
  using (is_admin());

-- Cross-dealer search, for logged-in dealers only. Deliberately excludes cost/supplier
-- so no dealer can see another dealer's margins — only what a buyer needs to know.
drop view if exists dealer_network_view;
create or replace view dealer_network_view
  with (security_invoker = false) as
  select
    i.id, i.dealer_id, d.shop_name as dealer_name, d.phone as dealer_phone,
    i.item_type, i.model, i.storage, i.color, i.condition, i.battery, i.price, i.updated_at,
    i.brand, i.cpu, i.ram, i.screen_size, i.gpu,
    i.image_url, i.image_urls
  from inventory i
  join dealers d on d.id = i.dealer_id
  where i.status = 'In Stock';
grant select on dealer_network_view to authenticated;

-- Public storefront catalog for the Customer App (one dealer's in-stock phones
-- and laptops only, no cost/supplier/IMEI exposed).
drop view if exists public_catalog;
create or replace view public_catalog
  with (security_invoker = false) as
  select id, dealer_id, item_type, model, storage, color, condition, battery, price, status,
         brand, cpu, ram, screen_size, gpu, image_url, image_urls
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

drop policy if exists "sales_all_own" on sales;
create policy "sales_all_own" on sales for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());

drop policy if exists "sales_select_admin" on sales;
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
drop function if exists sell_phone(text,numeric,text,text,text,text,int,text,text);
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
drop policy if exists "requests_insert_anyone" on requests;
create policy "requests_insert_anyone" on requests for insert
  with check (true);

-- Only the shop it was sent to (or an admin) can read/manage it.
drop policy if exists "requests_select_own" on requests;
create policy "requests_select_own" on requests for select
  using (dealer_id = auth.uid());
drop policy if exists "requests_update_own" on requests;
create policy "requests_update_own" on requests for update
  using (dealer_id = auth.uid());
drop policy if exists "requests_select_admin" on requests;
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

-- Links a saved contact directly to their PhoneHub account, when they have
-- one. Set by the "pick from registered dealers" suggestion dropdown when
-- adding/editing a contact. This is the reliable way to target a private
-- broadcast — no phone-number matching required, and it can't break if a
-- dealer's saved phone number is formatted differently from their account.
alter table suppliers add column if not exists linked_dealer_id uuid references dealers(id) on delete set null;
create index if not exists idx_suppliers_linked_dealer on suppliers(linked_dealer_id);

alter table suppliers enable row level security;
drop policy if exists "suppliers_all_own" on suppliers;
create policy "suppliers_all_own" on suppliers for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());
drop policy if exists "suppliers_select_admin" on suppliers;
create policy "suppliers_select_admin" on suppliers for select
  using (is_admin());

-- ------------------------------------------------------------
-- 5b. INVENTORY <-> SUPPLIERS  (link phones to a tracked contact by id, not name)
-- ------------------------------------------------------------
alter table inventory add column if not exists supplier_id uuid references suppliers(id) on delete set null;
create index if not exists idx_inventory_supplier_id on inventory(supplier_id);

-- One-time backfill: match existing inventory.supplier text to a contact with
-- the same name (case/whitespace-insensitive), for the same dealer.
update inventory i
set supplier_id = s.id
from suppliers s
where i.supplier_id is null
  and i.supplier is not null
  and s.dealer_id = i.dealer_id
  and lower(trim(i.supplier)) = lower(trim(s.name));

-- ------------------------------------------------------------
-- 6. BROADCASTS + RESPONSES  (network-wide "need this phone urgently", or a
--    "Stock" advert for one or more inventory items being offered for sale —
--    now with a visibility scope so a stock advert can be sent either to the
--    whole network or privately to a specific list of dealers, e.g. your
--    saved contacts who have PhoneHub accounts)
-- ------------------------------------------------------------
create table if not exists broadcasts (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references dealers(id) on delete cascade,   -- who's asking / advertising
  date date not null default current_date,
  type text not null default 'Need' check (type in ('Need','Stock')),
  model text not null,        -- for type='Stock' with multiple items, a summary label (e.g. "3 phones")
  storage text,
  color text,
  urgency text,
  items jsonb not null default '[]'::jsonb,   -- type='Stock': [{inventory_id, model, storage, color, condition, price, image_url, image_urls}, ...]
  message text,                                -- optional free-text note shown with a Stock advert
  status text not null default 'Open' check (status in ('Open','Closed')),
  accepted_response_id uuid,
  created_at timestamptz not null default now()
);

-- Visibility scope: 'network' (default, everyone sees it — the old behavior)
-- or 'private' (only the dealers listed in target_dealer_ids can see/be
-- notified about it — used for "send to my saved contacts").
alter table broadcasts add column if not exists visibility text not null default 'network'
  check (visibility in ('network','private'));
alter table broadcasts add column if not exists target_dealer_ids uuid[] not null default '{}';

alter table broadcasts enable row level security;

-- Every registered dealer can see every OPEN-MARKET broadcast (the old
-- behavior). Private broadcasts are only visible to: the sender, and any
-- dealer whose id appears in target_dealer_ids — so a broadcast sent to your
-- saved contacts is only ever seen by exactly those contacts, all of them,
-- not just one.
drop policy if exists "broadcasts_select_all" on broadcasts;
drop policy if exists "broadcasts_select_scoped" on broadcasts;
create policy "broadcasts_select_scoped" on broadcasts for select
  using (
    dealer_id = auth.uid()
    or (visibility = 'network' and auth.uid() is not null)
    or (visibility = 'private' and auth.uid() = any(target_dealer_ids))
  );

drop policy if exists "broadcasts_insert_own" on broadcasts;
create policy "broadcasts_insert_own" on broadcasts for insert
  with check (dealer_id = auth.uid());
drop policy if exists "broadcasts_update_own" on broadcasts;
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

-- Responses are only visible to whoever can see the underlying broadcast —
-- this keeps a private (saved-contacts) broadcast's responses private too.
drop policy if exists "broadcast_responses_select_all" on broadcast_responses;
drop policy if exists "broadcast_responses_select_scoped" on broadcast_responses;
create policy "broadcast_responses_select_scoped" on broadcast_responses for select
  using (
    exists (
      select 1 from broadcasts b
      where b.id = broadcast_responses.broadcast_id
        and (
          b.dealer_id = auth.uid()
          or (b.visibility = 'network' and auth.uid() is not null)
          or (b.visibility = 'private' and auth.uid() = any(b.target_dealer_ids))
        )
    )
  );

drop policy if exists "broadcast_responses_insert_own" on broadcast_responses;
drop policy if exists "broadcast_responses_insert_scoped" on broadcast_responses;
create policy "broadcast_responses_insert_scoped" on broadcast_responses for insert
  with check (
    dealer_id = auth.uid()
    and exists (
      select 1 from broadcasts b
      where b.id = broadcast_responses.broadcast_id
        and b.status = 'Open'
        and (
          (b.visibility = 'network' and auth.uid() is not null)
          or (b.visibility = 'private' and auth.uid() = any(b.target_dealer_ids))
        )
    )
  );

-- ------------------------------------------------------------
-- 6b. CONSIGNMENTS  ("Owed to you" — phones colleagues collected from you on
--     credit, and what they still owe. A private ledger, not network-visible.)
-- ------------------------------------------------------------
create table if not exists consignments (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references dealers(id) on delete cascade,
  contact_id uuid references suppliers(id) on delete set null,
  contact_name text not null,
  contact_phone text,
  inventory_id uuid references inventory(id) on delete set null,
  model text not null,
  storage text,
  color text,
  imei text,
  quantity int not null default 1,
  unit_price numeric not null default 0,
  amount_paid numeric not null default 0,
  status text not null default 'Out' check (status in ('Out','Partially Paid','Settled','Returned')),
  date_given date not null default current_date,
  due_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_consignments_dealer on consignments(dealer_id);
alter table consignments enable row level security;

drop policy if exists "consignments_all_own" on consignments;
create policy "consignments_all_own" on consignments for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());
drop policy if exists "consignments_select_admin" on consignments;
create policy "consignments_select_admin" on consignments for select
  using (is_admin());

-- ------------------------------------------------------------
-- 6c. CONSIGNMENT PAYMENTS  (payment log behind each "Owed to you" entry —
--     powers the detail dialog opened by clicking a row)
-- ------------------------------------------------------------
create table if not exists consignment_payments (
  id uuid primary key default gen_random_uuid(),
  consignment_id uuid not null references consignments(id) on delete cascade,
  dealer_id uuid not null references dealers(id) on delete cascade,
  amount numeric not null,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists idx_consignment_payments_consignment on consignment_payments(consignment_id);
alter table consignment_payments enable row level security;

drop policy if exists "consignment_payments_all_own" on consignment_payments;
create policy "consignment_payments_all_own" on consignment_payments for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());
drop policy if exists "consignment_payments_select_admin" on consignment_payments;
create policy "consignment_payments_select_admin" on consignment_payments for select
  using (is_admin());

-- ------------------------------------------------------------
-- 6d. STOCK BROADCAST LOG  — kept for backwards compatibility with any old
--     rows, but no longer written to. "Send to saved contacts" now creates a
--     real (private-visibility) row in `broadcasts` instead, so it shows up
--     in-app with push notifications, the same as an open-market broadcast.
-- ------------------------------------------------------------
create table if not exists stock_broadcast_log (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references dealers(id) on delete cascade,
  contact_names text,
  items jsonb not null default '[]'::jsonb,
  message text,
  created_at timestamptz not null default now()
);
alter table stock_broadcast_log enable row level security;

drop policy if exists "stock_broadcast_log_all_own" on stock_broadcast_log;
create policy "stock_broadcast_log_all_own" on stock_broadcast_log for all
  using (dealer_id = auth.uid())
  with check (dealer_id = auth.uid());

-- ------------------------------------------------------------
-- 6e. DEALER REPUTATION VIEW
-- ------------------------------------------------------------
drop view if exists dealer_reputation_view;
create or replace view dealer_reputation_view
  with (security_invoker = false) as
  with resp as (
    select br.dealer_id,
           count(*) as responses_count,
           count(*) filter (where b.accepted_response_id = br.id) as accepted_count,
           avg(extract(epoch from (br.created_at - b.created_at))/60.0) as avg_response_minutes
    from broadcast_responses br
    join broadcasts b on b.id = br.broadcast_id
    group by br.dealer_id
  )
  select
    d.id as dealer_id, d.shop_name,
    coalesce(r.responses_count,0) as responses_count,
    coalesce(r.accepted_count,0) as accepted_count,
    case when coalesce(r.responses_count,0) = 0 then null
         else round(100.0 * coalesce(r.accepted_count,0) / r.responses_count) end as fulfillment_rate_pct,
    round(r.avg_response_minutes) as avg_response_minutes,
    case
      when coalesce(r.responses_count,0) = 0 then 'new'
      when r.responses_count >= 20 and coalesce(r.accepted_count,0)::numeric / r.responses_count >= 0.5 then 'elite'
      when r.responses_count >= 5 then 'trusted'
      else 'active'
    end as tier
  from dealers d
  left join resp r on r.dealer_id = d.id;
grant select on dealer_reputation_view to authenticated;

-- ------------------------------------------------------------
-- 7. REALTIME  (required for the seller app's live broadcast updates)
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'broadcasts'
  ) then
    alter publication supabase_realtime add table broadcasts;
  end if;
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'broadcast_responses'
  ) then
    alter publication supabase_realtime add table broadcast_responses;
  end if;
end $$;

-- ------------------------------------------------------------
-- 8. STORAGE  (phone photos — public read, dealers can only manage their own folder)
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
  values ('phone-images', 'phone-images', true)
  on conflict (id) do nothing;

drop policy if exists "phone_images_public_read" on storage.objects;
create policy "phone_images_public_read" on storage.objects for select
  using (bucket_id = 'phone-images');

drop policy if exists "phone_images_insert_own" on storage.objects;
create policy "phone_images_insert_own" on storage.objects for insert
  with check (bucket_id = 'phone-images' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "phone_images_update_own" on storage.objects;
create policy "phone_images_update_own" on storage.objects for update
  using (bucket_id = 'phone-images' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "phone_images_delete_own" on storage.objects;
create policy "phone_images_delete_own" on storage.objects for delete
  using (bucket_id = 'phone-images' and (storage.foldername(name))[1] = auth.uid()::text);

-- ------------------------------------------------------------
-- 9. APP CONFIG + PUSH NOTIFICATION TRIGGER FOR BROADCASTS
--    Fires the send-push Edge Function whenever a broadcast is inserted.
--    For a 'network' broadcast: notifies every dealer except the sender.
--    For a 'private' broadcast: notifies only the dealers in target_dealer_ids
--    (i.e. every one of your saved contacts who has a PhoneHub account —
--    not just the first match).
-- ------------------------------------------------------------
create table if not exists app_config (key text primary key, value text);
insert into app_config(key, value) values
  ('edge_function_url', 'https://YOUR-PROJECT-REF.functions.supabase.co/send-push'),
  ('edge_function_secret', 'YOUR_WEBHOOK_SECRET')
on conflict (key) do nothing;
-- ^^^ Edit these two values to your real Edge Function URL and webhook secret.
-- (Find them again any time with: select * from app_config;)

create or replace function notify_broadcast_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text; v_title text; v_body text;
begin
  select value into v_url from app_config where key='edge_function_url';
  select value into v_secret from app_config where key='edge_function_secret';
  if v_url is null then return new; end if;

  v_title := case when new.type='Need' then 'Dealer needs: '||new.model else 'New stock advert' end;
  v_body := coalesce(new.message, new.model);

  if new.visibility = 'private' then
    if array_length(new.target_dealer_ids,1) is null then return new; end if;
    perform net.http_post(
      url := v_url,
      headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', v_secret),
      body := jsonb_build_object('dealer_ids', to_jsonb(new.target_dealer_ids),
        'title', v_title, 'body', v_body, 'url', './#tab=network', 'type', 'broadcast')
    );
  else
    perform net.http_post(
      url := v_url,
      headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', v_secret),
      body := jsonb_build_object('exclude_dealer_id', new.dealer_id,
        'title', v_title, 'body', v_body, 'url', './#tab=network', 'type', 'broadcast')
    );
  end if;
  return new;
end; $$;

drop trigger if exists trg_notify_broadcast_push on broadcasts;
create trigger trg_notify_broadcast_push after insert on broadcasts
for each row execute function notify_broadcast_push();

-- ------------------------------------------------------------
-- 10. FALLBACK LOOKUP — matches saved-contact phone numbers to dealer
--     accounts, for any older contacts that predate the linked_dealer_id
--     picker. Prefer linked_dealer_id when it's set; only fall back to this
--     for contacts that were never linked.
-- ------------------------------------------------------------
create or replace function find_dealers_by_phone(p_phones text[])
returns table(input_phone text, dealer_id uuid, shop_name text)
language sql security definer set search_path = public
as $$
  select ph, d.id, d.shop_name
  from unnest(p_phones) as ph
  join dealers d
    on regexp_replace(d.phone, '[^0-9]', '', 'g') = regexp_replace(ph, '[^0-9]', '', 'g')
  where auth.uid() is not null and d.id <> auth.uid();
$$;
grant execute on function find_dealers_by_phone(text[]) to authenticated;

-- ============================================================
-- After running this file:
-- 1. Sign up your own account through the Seller App (this creates your dealer row).
-- 2. Run:  update dealers set is_admin = true where shop_slug = 'your-shop-slug';
--    (or `where id = 'your-auth-user-id'` — find it in Authentication > Users)
-- 3. Edit the two app_config rows in section 9 with your real Edge Function
--    URL and webhook secret (or leave them if you already have push working).
-- ============================================================
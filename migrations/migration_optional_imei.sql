-- ============================================================
-- PhoneHub Pro — Migration: make IMEI optional
-- ============================================================
-- ONLY needed if you already ran an OLDER version of schema.sql that had
-- IMEI as NOT NULL. The schema.sql in this package already has IMEI as
-- optional and sell_phone() matching by inventory id — skip this file
-- entirely on a fresh project.
--
-- Run this once in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- Safe to re-run.
-- ============================================================

-- 1. Allow phones/sales to be saved without an IMEI (e.g. accessories,
--    or stock not yet logged with its IMEI).
alter table inventory alter column imei drop not null;
alter table sales alter column imei drop not null;

-- 2. Replace sell_phone() to match by the phone's internal id instead of
--    its IMEI. This avoids ambiguity now that IMEI can be blank (multiple
--    IMEI-less phones would otherwise be indistinguishable when selling).
drop function if exists sell_phone(text,numeric,text,text,text,text,int,text,text);

create or replace function sell_phone(
  p_inventory_id uuid, p_sale_price numeric, p_customer_name text, p_customer_phone text,
  p_payment_method text, p_staff text, p_warranty_days int, p_accessories text, p_notes text
)
returns sales
language plpgsql
as $$
declare
  v_phone inventory%rowtype;
  v_sale sales%rowtype;
begin
  select * into v_phone from inventory
    where id = p_inventory_id and dealer_id = auth.uid() and status = 'In Stock'
    limit 1;

  if v_phone.id is null then
    raise exception 'No in-stock phone found for that selection';
  end if;

  insert into sales (dealer_id, imei, model, cost, sale_price, customer_name, customer_phone,
                      payment_method, staff, warranty_days, accessories, notes)
  values (auth.uid(), v_phone.imei, v_phone.model, v_phone.cost, p_sale_price, p_customer_name, p_customer_phone,
          p_payment_method, p_staff, p_warranty_days, p_accessories, p_notes)
  returning * into v_sale;

  update inventory set status = 'Sold', updated_at = now() where id = v_phone.id;

  return v_sale;
end;
$$;
grant execute on function sell_phone(uuid,numeric,text,text,text,text,int,text,text) to authenticated;

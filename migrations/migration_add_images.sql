-- ============================================================
-- PhoneHub Pro — Migration: add phone photos
-- ============================================================
-- Only needed if you already ran an OLDER version of schema.sql before
-- image support was added. The schema.sql in this package already
-- includes everything below — skip this file on a fresh project.
--
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- Safe to re-run.
-- ============================================================

alter table inventory add column if not exists image_url text;

drop view if exists dealer_network_view;
create or replace view dealer_network_view
  with (security_invoker = false) as
  select
    i.id, i.dealer_id, d.shop_name as dealer_name, d.phone as dealer_phone,
    i.model, i.storage, i.color, i.condition, i.battery, i.price, i.updated_at, i.image_url
  from inventory i
  join dealers d on d.id = i.dealer_id
  where i.status = 'In Stock';

drop view if exists public_catalog;
create or replace view public_catalog
  with (security_invoker = false) as
  select id, dealer_id, model, storage, color, condition, battery, price, status, image_url
  from inventory
  where status = 'In Stock';

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

-- Migration: sub-dealer / agent linking — one active principal at a time
--
-- Model:
--   - A "sub-dealer" is a dealer account with no inventory of their own,
--     representing exactly one principal dealer's stock at any given time.
--   - A sub-dealer can request a link to a principal (or a principal can
--     invite a specific sub-dealer) — either way, BOTH sides must consent
--     before the link goes 'active'.
--   - Strictly two-tier: a sub-dealer can never themselves be a principal
--     to other sub-dealers, and a dealer who already has sub-dealers under
--     them cannot become someone else's sub-dealer. Enforced both in the
--     RPCs (friendly error messages) and via a DB trigger (hard backstop).
--   - Only ONE in-flight link (pending / active / release_requested) is
--     allowed per sub-dealer at a time — enforced by a partial unique
--     index. To switch principals, the sub-dealer must fully exit their
--     current link first:
--       1. Sub-dealer calls request_subdealer_release() on their active link
--       2. Current principal calls approve_subdealer_release() to let them go
--          (or the principal can immediately revoke_subdealer_link() any time,
--          no consent needed from the sub-dealer for that direction)
--       3. Sub-dealer is now free to request_subdealer_link() with a new
--          principal, who must approve_subdealer_link() to activate it
--   - Full history is kept (ended/revoked rows are never deleted) so both
--     sides — and admins — can see past relationships.
--
-- NOT covered by this migration (deliberately out of scope for now):
--   - KYC document upload/verification for sub-dealer accounts
--   - Commission payout calculation / integration into sell_phone()
--   - Any UI — this is the data + RPC layer only
--
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS.
-- Run in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- ============================================================

-- 1. Flag a dealer account as a sub-dealer/agent (no inventory of their own).
--    Set automatically the first time a link request succeeds — see the
--    RPCs below. Real KYC (ID + selfie + principal's explicit written
--    consent) should gate this before any real money commission flows,
--    but that's a separate feature to build on top of this.
alter table dealers add column if not exists is_sub_dealer boolean not null default false;
comment on column dealers.is_sub_dealer is
  'True if this dealer account operates as a sub-dealer/agent — sells on behalf of a principal dealer''s stock, no inventory of their own. Can never itself be a principal to other sub-dealers (enforced by trg_check_subdealer_link_tiers).';

-- 2. The link table itself.
create table if not exists sub_dealer_links (
  id uuid primary key default gen_random_uuid(),
  sub_dealer_id uuid not null references dealers(id) on delete cascade,
  principal_dealer_id uuid not null references dealers(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending','active','release_requested','ended','revoked')),
  commission_type text check (commission_type in ('flat','percent')),
  commission_value numeric,
  requested_by text not null default 'sub_dealer' check (requested_by in ('sub_dealer','principal')),
  ended_reason text check (
    ended_reason is null or ended_reason in (
      'rejected_by_principal','cancelled_by_sub_dealer',
      'released_by_principal','revoked_by_principal'
    )
  ),
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  ended_at timestamptz,
  check (sub_dealer_id <> principal_dealer_id)
);

create index if not exists idx_sdl_sub_dealer on sub_dealer_links(sub_dealer_id);
create index if not exists idx_sdl_principal on sub_dealer_links(principal_dealer_id);

-- Only one in-flight link per sub-dealer at a time (pending, active, or
-- mid-release). This is what makes the "clean handoff" model work — a
-- second request simply cannot be created until the current one reaches a
-- terminal state (ended/revoked). Race-condition safe since it's a real
-- unique index, not an application-level check.
create unique index if not exists uniq_inflight_link_per_subdealer
  on sub_dealer_links(sub_dealer_id)
  where status in ('pending','active','release_requested');

-- 3. Hard backstop: a sub-dealer can never be listed as someone else's
--    principal. (The RPCs below also check this up front for a friendlier
--    error message — this trigger is the last line of defense against any
--    direct insert bypassing the RPCs.)
create or replace function check_subdealer_link_tiers()
returns trigger language plpgsql as $$
declare
  v_principal_is_sub boolean;
begin
  select is_sub_dealer into v_principal_is_sub from dealers where id = new.principal_dealer_id;
  if v_principal_is_sub then
    raise exception 'A sub-dealer account cannot act as a principal for other sub-dealers';
  end if;
  return new;
end; $$;

drop trigger if exists trg_check_subdealer_link_tiers on sub_dealer_links;
create trigger trg_check_subdealer_link_tiers before insert on sub_dealer_links
for each row execute function check_subdealer_link_tiers();

-- 4. RLS — read-only for the two parties involved (+ admin). All writes go
--    through the security-definer functions below, which enforce the state
--    machine and ownership checks manually. No direct insert/update
--    policies, so a client can't hand-craft a row that skips a consent step.
alter table sub_dealer_links enable row level security;

drop policy if exists "sdl_select_related" on sub_dealer_links;
create policy "sdl_select_related" on sub_dealer_links for select
  using (sub_dealer_id = auth.uid() or principal_dealer_id = auth.uid() or is_admin());

-- ------------------------------------------------------------
-- 5. RPCs — sub-dealer-initiated request flow
-- ------------------------------------------------------------

-- Sub-dealer requests a link to a principal. Auto-flags the caller as a
-- sub-dealer on first successful request. Blocks the request if the caller
-- is currently someone else's principal (keeps the tree strictly two-level
-- in both directions) or already has an in-flight link of their own.
create or replace function request_subdealer_link(
  p_principal_id uuid, p_commission_type text default null, p_commission_value numeric default null
)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare
  v_row sub_dealer_links;
  v_principal_is_sub boolean;
  v_caller_is_principal_elsewhere boolean;
begin
  if p_principal_id = auth.uid() then
    raise exception 'Cannot link to yourself';
  end if;

  select is_sub_dealer into v_principal_is_sub from dealers where id = p_principal_id;
  if v_principal_is_sub then
    raise exception 'That account is itself a sub-dealer and cannot take on sub-dealers of its own';
  end if;

  select exists(
    select 1 from sub_dealer_links
    where principal_dealer_id = auth.uid() and status in ('pending','active','release_requested')
  ) into v_caller_is_principal_elsewhere;
  if v_caller_is_principal_elsewhere then
    raise exception 'You currently have your own sub-dealers linked to you — a dealer cannot be both a principal and a sub-dealer';
  end if;

  insert into sub_dealer_links (sub_dealer_id, principal_dealer_id, status, commission_type, commission_value, requested_by)
  values (auth.uid(), p_principal_id, 'pending', p_commission_type, p_commission_value, 'sub_dealer')
  returning * into v_row;

  update dealers set is_sub_dealer = true where id = auth.uid() and is_sub_dealer is distinct from true;

  return v_row;
exception
  when unique_violation then
    raise exception 'You already have an active or pending principal link — end it first before requesting a new one';
end; $$;
grant execute on function request_subdealer_link(uuid, text, numeric) to authenticated;

-- Principal approves a sub-dealer-initiated request.
create or replace function approve_subdealer_link(
  p_link_id uuid, p_commission_type text default null, p_commission_value numeric default null
)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare v_row sub_dealer_links;
begin
  update sub_dealer_links
    set status = 'active',
        activated_at = now(),
        commission_type = coalesce(p_commission_type, commission_type),
        commission_value = coalesce(p_commission_value, commission_value)
    where id = p_link_id and principal_dealer_id = auth.uid()
      and status = 'pending' and requested_by = 'sub_dealer'
    returning * into v_row;

  if v_row.id is null then raise exception 'No pending request found for you to approve'; end if;
  return v_row;
end; $$;
grant execute on function approve_subdealer_link(uuid, text, numeric) to authenticated;

-- Principal rejects a sub-dealer-initiated request.
create or replace function reject_subdealer_link(p_link_id uuid)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare v_row sub_dealer_links;
begin
  update sub_dealer_links
    set status = 'ended', ended_at = now(), ended_reason = 'rejected_by_principal'
    where id = p_link_id and principal_dealer_id = auth.uid()
      and status = 'pending' and requested_by = 'sub_dealer'
    returning * into v_row;

  if v_row.id is null then raise exception 'No pending request found for you to reject'; end if;
  return v_row;
end; $$;
grant execute on function reject_subdealer_link(uuid) to authenticated;

-- Sub-dealer withdraws their own still-pending request.
create or replace function cancel_own_subdealer_request(p_link_id uuid)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare v_row sub_dealer_links;
begin
  update sub_dealer_links
    set status = 'ended', ended_at = now(), ended_reason = 'cancelled_by_sub_dealer'
    where id = p_link_id and sub_dealer_id = auth.uid()
      and status = 'pending' and requested_by = 'sub_dealer'
    returning * into v_row;

  if v_row.id is null then raise exception 'No pending request found to cancel'; end if;
  return v_row;
end; $$;
grant execute on function cancel_own_subdealer_request(uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. RPCs — principal-initiated invite flow (mirror of the above)
-- ------------------------------------------------------------

-- Principal invites a specific dealer to become their sub-dealer.
create or replace function invite_subdealer_link(
  p_subdealer_id uuid, p_commission_type text default null, p_commission_value numeric default null
)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare
  v_row sub_dealer_links;
  v_caller_is_sub boolean;
begin
  if p_subdealer_id = auth.uid() then
    raise exception 'Cannot link to yourself';
  end if;

  select is_sub_dealer into v_caller_is_sub from dealers where id = auth.uid();
  if v_caller_is_sub then
    raise exception 'A sub-dealer account cannot invite sub-dealers of its own';
  end if;

  insert into sub_dealer_links (sub_dealer_id, principal_dealer_id, status, commission_type, commission_value, requested_by)
  values (p_subdealer_id, auth.uid(), 'pending', p_commission_type, p_commission_value, 'principal')
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'That dealer already has an active or pending principal link';
end; $$;
grant execute on function invite_subdealer_link(uuid, text, numeric) to authenticated;

-- Invited sub-dealer accepts. Same two-tier / one-in-flight checks as
-- request_subdealer_link(), since this is the moment they actually become
-- a sub-dealer in practice.
create or replace function accept_subdealer_invite(
  p_link_id uuid, p_commission_type text default null, p_commission_value numeric default null
)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare
  v_row sub_dealer_links;
  v_caller_is_principal_elsewhere boolean;
begin
  select exists(
    select 1 from sub_dealer_links
    where principal_dealer_id = auth.uid() and status in ('pending','active','release_requested')
  ) into v_caller_is_principal_elsewhere;
  if v_caller_is_principal_elsewhere then
    raise exception 'You currently have your own sub-dealers linked to you — a dealer cannot be both a principal and a sub-dealer';
  end if;

  update sub_dealer_links
    set status = 'active', activated_at = now(),
        commission_type = coalesce(p_commission_type, commission_type),
        commission_value = coalesce(p_commission_value, commission_value)
    where id = p_link_id and sub_dealer_id = auth.uid()
      and status = 'pending' and requested_by = 'principal'
    returning * into v_row;

  if v_row.id is null then raise exception 'No pending invite found for you to accept'; end if;

  update dealers set is_sub_dealer = true where id = auth.uid() and is_sub_dealer is distinct from true;

  return v_row;
end; $$;
grant execute on function accept_subdealer_invite(uuid, text, numeric) to authenticated;

-- Invited sub-dealer declines.
create or replace function decline_subdealer_invite(p_link_id uuid)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare v_row sub_dealer_links;
begin
  update sub_dealer_links
    set status = 'ended', ended_at = now(), ended_reason = 'cancelled_by_sub_dealer'
    where id = p_link_id and sub_dealer_id = auth.uid()
      and status = 'pending' and requested_by = 'principal'
    returning * into v_row;

  if v_row.id is null then raise exception 'No pending invite found to decline'; end if;
  return v_row;
end; $$;
grant execute on function decline_subdealer_invite(uuid) to authenticated;

-- ------------------------------------------------------------
-- 7. RPCs — ending an active link (the "clean handoff" mechanics)
-- ------------------------------------------------------------

-- Sub-dealer asks to leave their current active link. Does NOT end it
-- immediately — the principal must approve the release. This gives the
-- principal a chance to settle any outstanding commission/consignment
-- balance before the relationship formally ends.
create or replace function request_subdealer_release(p_link_id uuid)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare v_row sub_dealer_links;
begin
  update sub_dealer_links
    set status = 'release_requested'
    where id = p_link_id and sub_dealer_id = auth.uid() and status = 'active'
    returning * into v_row;

  if v_row.id is null then raise exception 'No active link found to release'; end if;
  return v_row;
end; $$;
grant execute on function request_subdealer_release(uuid) to authenticated;

-- Principal approves the release. Once this runs, the sub-dealer is free
-- to request/accept a link with a different principal.
create or replace function approve_subdealer_release(p_link_id uuid)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare v_row sub_dealer_links;
begin
  update sub_dealer_links
    set status = 'ended', ended_at = now(), ended_reason = 'released_by_principal'
    where id = p_link_id and principal_dealer_id = auth.uid() and status = 'release_requested'
    returning * into v_row;

  if v_row.id is null then raise exception 'No release request found for you to approve'; end if;
  return v_row;
end; $$;
grant execute on function approve_subdealer_release(uuid) to authenticated;

-- Principal can terminate a link at ANY stage (pending, active, or
-- mid-release) unilaterally — no consent needed from the sub-dealer for
-- this direction, since a principal should always be able to cut off
-- someone representing their stock immediately if something's wrong.
create or replace function revoke_subdealer_link(p_link_id uuid)
returns sub_dealer_links
language plpgsql
security definer set search_path = public
as $$
declare v_row sub_dealer_links;
begin
  update sub_dealer_links
    set status = 'revoked', ended_at = now(), ended_reason = 'revoked_by_principal'
    where id = p_link_id and principal_dealer_id = auth.uid()
      and status in ('pending','active','release_requested')
    returning * into v_row;

  if v_row.id is null then raise exception 'No linkable request found for you to revoke'; end if;
  return v_row;
end; $$;
grant execute on function revoke_subdealer_link(uuid) to authenticated;

-- ------------------------------------------------------------
-- 8. Convenience view — "my current link" for whichever side is calling.
--    Scoped by the underlying table's RLS (security_invoker), so it only
--    ever shows rows the caller is actually part of.
-- ------------------------------------------------------------
create or replace view my_subdealer_link_view
  with (security_invoker = true) as
  select
    l.*,
    dp.shop_name as principal_shop_name, dp.phone as principal_phone,
    ds.shop_name as sub_dealer_shop_name, ds.phone as sub_dealer_phone
  from sub_dealer_links l
  join dealers dp on dp.id = l.principal_dealer_id
  join dealers ds on ds.id = l.sub_dealer_id
  where l.status in ('pending','active','release_requested');
grant select on my_subdealer_link_view to authenticated;

-- ============================================================
-- After running this:
-- - A dealer can call request_subdealer_link(principal_id) to ask to become
--   someone's sub-dealer, or a principal can call
--   invite_subdealer_link(subdealer_id) to invite a specific dealer.
-- - Both sides need to be able to look up each other's dealer id — reuse
--   the existing public_shops view / "search dealer directory" pattern
--   already used for suppliers.linked_dealer_id in the Seller App.
-- - Query my_subdealer_link_view (as the sub-dealer) to show "you're linked
--   to X" / "pending approval from Y" / "free to link" in the UI, and query
--   sub_dealer_links directly (as a principal) filtered to
--   principal_dealer_id = auth.uid() to list all sub-dealers under them,
--   past and present.
-- - Commission calculation is NOT wired into sell_phone() yet — that's the
--   next piece once this linking flow is tested, and it'll need to resolve
--   which inventory rows a sub-dealer is allowed to sell (their active
--   principal's stock only) and record a commission-owed entry per sale,
--   likely reusing the consignment_payments pattern already in the schema.
-- - Real KYC (ID + selfie + explicit written consent capture) for sub-dealer
--   accounts is a separate feature to build before any real money changes
--   hands on commission — this migration only handles the relationship
--   state machine, not identity verification.
-- ============================================================
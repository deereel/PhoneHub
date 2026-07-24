-- Migration: quiet down network-wide broadcast push notifications
--
-- Problem being fixed:
--   notify_broadcast_push() previously pushed to EVERY dealer (minus the
--   sender) for every single network-visibility broadcast. With many dealers
--   on the platform, this becomes constant, unwanted noise and drives people
--   to mute or uninstall the app.
--
-- What this migration does:
--   1. Adds dealers.notify_network_broadcasts (default false) — an opt-in
--      flag for dealers who WANT to be pushed for open-market broadcasts.
--   2. Adds dealers.brand_focus (text[], default '{}', max 3 recommended,
--      enforced client-side) — lets an opted-in dealer narrow pushes to only
--      the brands they deal in (e.g. {'iPhone','Samsung'}). Empty = all
--      brands.
--   3. Replaces notify_broadcast_push() so that:
--        - visibility = 'private'  -> unchanged: always pushes to
--          target_dealer_ids (these are direct, addressed broadcasts).
--        - visibility = 'network'  -> no longer pushes to everyone. Instead
--          only pushes to dealers who have notify_network_broadcasts = true,
--          AND (their brand_focus is empty OR the broadcast's model/items
--          mention one of their focus brands).
--   Every dealer still SEES all open-market broadcasts in the Network tab
--   (via the existing dealer_network / broadcasts realtime subscription and
--   pill-badge count) — this migration only changes who gets buzzed on
--   their phone for it.
--
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS.
-- Run in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- ============================================================

-- 1. New dealer preference columns
alter table dealers add column if not exists notify_network_broadcasts boolean not null default false;
alter table dealers add column if not exists brand_focus text[] not null default '{}';

comment on column dealers.notify_network_broadcasts is
  'If true, this dealer receives push notifications for open-market (visibility=network) broadcasts, not just private ones addressed directly to them. Default false to avoid notification fatigue.';
comment on column dealers.brand_focus is
  'Optional list (recommended max 3) of brand keywords, e.g. {"iPhone","Samsung"}. When notify_network_broadcasts is true and this is non-empty, only network broadcasts whose model/items text matches one of these brands will be pushed to this dealer. Empty array = no brand filtering (push for everything, if opted in).';

-- 2. Helper: does a broadcast's content mention any of a dealer's focus brands?
--    Checks the top-level model/storage/color text plus every item inside the
--    items jsonb array (for multi-item "Stock" adverts), case-insensitively.
create or replace function broadcast_matches_brand_focus(p_broadcast broadcasts, p_brand_focus text[])
returns boolean
language sql
stable
as $$
  select
    -- empty focus list = no filtering, matches everything
    (p_brand_focus is null or array_length(p_brand_focus,1) is null)
    or exists (
      select 1 from unnest(p_brand_focus) as brand
      where
        p_broadcast.model ilike '%' || brand || '%'
        or coalesce(p_broadcast.storage,'') ilike '%' || brand || '%'
        or coalesce(p_broadcast.color,'') ilike '%' || brand || '%'
        or exists (
          select 1 from jsonb_array_elements(coalesce(p_broadcast.items, '[]'::jsonb)) as it
          where (it->>'model') ilike '%' || brand || '%'
             or coalesce(it->>'brand','') ilike '%' || brand || '%'
        )
    );
$$;

-- 3. Replace the broadcast push trigger function
create or replace function notify_broadcast_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_url text; v_secret text; v_title text; v_body text;
  v_target_ids uuid[];
begin
  select value into v_url from app_config where key='edge_function_url';
  select value into v_secret from app_config where key='edge_function_secret';
  if v_url is null then return new; end if;

  v_title := case when new.type='Need' then 'Dealer needs: '||new.model else 'New stock advert' end;
  v_body := coalesce(new.message, new.model);

  if new.visibility = 'private' then
    -- Unchanged: private broadcasts are addressed directly to specific
    -- dealers (e.g. "send to my saved contacts") and always push.
    if array_length(new.target_dealer_ids,1) is null then return new; end if;
    perform net.http_post(
      url := v_url,
      headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', v_secret),
      body := jsonb_build_object('dealer_ids', to_jsonb(new.target_dealer_ids),
        'title', v_title, 'body', v_body, 'url', './#tab=network', 'type', 'broadcast')
    );
  else
    -- Network (open-market) broadcasts: only push to dealers who opted in
    -- via notify_network_broadcasts, and (if they set one) whose brand_focus
    -- matches this broadcast's content. Everyone else still sees it via the
    -- Network tab badge/realtime subscription — just no push.
    select array_agg(d.id) into v_target_ids
    from dealers d
    where d.id <> new.dealer_id
      and d.notify_network_broadcasts = true
      and broadcast_matches_brand_focus(new, d.brand_focus);

    if v_target_ids is null or array_length(v_target_ids,1) is null then
      return new; -- nobody opted in / matched — no push, badge/realtime still updates for everyone
    end if;

    perform net.http_post(
      url := v_url,
      headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', v_secret),
      body := jsonb_build_object('dealer_ids', to_jsonb(v_target_ids),
        'title', v_title, 'body', v_body, 'url', './#tab=network', 'type', 'broadcast')
    );
  end if;
  return new;
end; $$;

-- Trigger itself is unchanged in shape, just re-pointed at the new function body.
drop trigger if exists trg_notify_broadcast_push on broadcasts;
create trigger trg_notify_broadcast_push after insert on broadcasts
for each row execute function notify_broadcast_push();

-- ============================================================
-- After running this:
-- - Every dealer's push behavior for network broadcasts defaults to OFF
--   (notify_network_broadcasts = false), matching the "quiet by default"
--   goal. Existing dealers are not opted in automatically.
-- - The Seller App's Notifications modal now exposes:
--     "Also alert me for open-market broadcasts" (toggle)
--     "Only alert me about these brands" (optional, up to 3, shown once the
--     toggle above is on)
-- - No changes needed to how broadcasts are inserted from the client —
--   this is entirely a database-side change.
-- ============================================================

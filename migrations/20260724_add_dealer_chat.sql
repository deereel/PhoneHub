-- Migration: 1:1 dealer-to-dealer chat
--
-- What this adds:
--   1. A `messages` table — plain text messages between two dealers.
--   2. RLS so a dealer can only ever see messages where they are the
--      sender or the recipient (same pattern as suppliers/consignments).
--   3. Adds `messages` to the realtime publication, so both sides see new
--      messages live without refreshing (same mechanism already used for
--      broadcasts/broadcast_responses).
--   4. A push-notification trigger (notify_new_message_push) that fires
--      the existing send-push Edge Function whenever a message is inserted,
--      so a dealer gets a phone alert for a new chat message even with the
--      app closed — same pattern as notify_new_request_push.
--
-- Who can message whom: any two registered dealers can technically message
-- each other once they know each other's dealer id (same trust boundary as
-- the open dealer network / broadcasts). The Seller App UI only ever lets a
-- dealer START a chat with a saved contact that has linked_dealer_id set
-- (i.e. a contact they've already confirmed is a real PhoneHub account) —
-- this migration doesn't restrict at the database level beyond that, to
-- keep it simple. Tighten later with a "only if a supplier row links you
-- both" check if you want it stricter.
--
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS.
-- Run in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- ============================================================

create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references dealers(id) on delete cascade,
  recipient_id uuid not null references dealers(id) on delete cascade,
  body text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_messages_sender on messages(sender_id);
create index if not exists idx_messages_recipient on messages(recipient_id);
create index if not exists idx_messages_conversation
  on messages(least(sender_id, recipient_id), greatest(sender_id, recipient_id), created_at);

alter table messages enable row level security;

drop policy if exists "messages_select_own" on messages;
create policy "messages_select_own" on messages for select
  using (sender_id = auth.uid() or recipient_id = auth.uid());

drop policy if exists "messages_insert_own" on messages;
create policy "messages_insert_own" on messages for insert
  with check (sender_id = auth.uid());

-- Recipients can update read_at on messages sent TO them (marking as read).
-- Senders cannot edit/retract message content this way (body is not
-- covered by this policy's typical use — Supabase update() from the client
-- should only ever send {read_at: ...} for this table).
drop policy if exists "messages_update_mark_read" on messages;
create policy "messages_update_mark_read" on messages for update
  using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

drop policy if exists "messages_select_admin" on messages;
create policy "messages_select_admin" on messages for select
  using (is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table messages;
  end if;
end $$;

-- Push notification: fires once per new message, same as
-- notify_new_request_push. Uses the same app_config edge_function_url /
-- edge_function_secret already set up for broadcasts and requests.
create or replace function notify_new_message_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_url text; v_secret text; v_sender_name text;
begin
  select value into v_url from app_config where key='edge_function_url';
  select value into v_secret from app_config where key='edge_function_secret';
  if v_url is null then return new; end if;

  select shop_name into v_sender_name from dealers where id = new.sender_id;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', v_secret),
    body := jsonb_build_object(
      'dealer_id', new.recipient_id,
      'title', 'New message from ' || coalesce(v_sender_name, 'a dealer'),
      'body', left(new.body, 120),
      'url', './#tab=chats', 'type', 'message'
    )
  );
  return new;
end; $$;

drop trigger if exists trg_notify_new_message_push on messages;
create trigger trg_notify_new_message_push after insert on messages
for each row execute function notify_new_message_push();

-- ============================================================
-- After running this:
-- - The `messages` table exists with RLS matching the rest of the schema.
-- - New messages push a notification to the recipient (respecting whatever
--   device push subscriptions they already have — no extra opt-in needed,
--   the same way a private broadcast or a customer request always pushes).
-- - Add sw.js routing for 'message' notifications (see CHATS_FEATURE_GUIDE.md)
--   so tapping the notification opens the Chats tab.
-- ============================================================

-- Migration: chat message editing, deleting, and image attachments
--
-- Adds to the `messages` table (created by 20260724_add_dealer_chat.sql):
--   1. image_url   — optional photo attached to a message (reuses the
--                     existing 'phone-images' storage bucket / upload path,
--                     same as phone/laptop/gadget photos).
--   2. edited_at   — set when the sender edits a message's text after
--                     sending. Null = never edited.
--   3. deleted_at  — set when the sender deletes a message. The row is kept
--                     (so both sides still see a "Message deleted" placeholder
--                     in the right spot in the thread) but body/image_url are
--                     cleared at delete time so the content is actually gone,
--                     not just hidden client-side.
--   4. A new RLS policy letting a sender update their OWN messages'
--      body/image_url/edited_at/deleted_at (previously only the recipient
--      could update a row, and only to set read_at).
--
-- Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS.
-- Run in Supabase: Dashboard > SQL Editor > New query > paste > Run.
-- ============================================================

alter table messages add column if not exists image_url text;
alter table messages add column if not exists edited_at timestamptz;
alter table messages add column if not exists deleted_at timestamptz;

comment on column messages.image_url is 'Optional photo attached to the message, stored in the phone-images bucket under the sender''s folder.';
comment on column messages.edited_at is 'Set when the sender edits the message body after sending. Null = never edited.';
comment on column messages.deleted_at is 'Set when the sender deletes the message. body/image_url are cleared at delete time; the row itself is kept so both sides see a placeholder in place.';

-- Senders can update their own messages (edit body, attach/clear image_url,
-- stamp edited_at, or soft-delete via deleted_at). This is separate from the
-- existing "messages_update_mark_read" policy (which only lets the
-- RECIPIENT set read_at) — Postgres RLS policies for the same command are
-- OR'd together, so both remain in effect for their respective use cases.
drop policy if exists "messages_update_sender" on messages;
create policy "messages_update_sender" on messages for update
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());

-- Push notification body should make sense for image-only messages too
-- (where body may be null/empty).
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
      'body', left(coalesce(nullif(new.body,''), case when new.image_url is not null then '📷 Photo' else '' end), 120),
      'url', './#tab=chats', 'type', 'message'
    )
  );
  return new;
end; $$;

-- ============================================================
-- After running this:
-- - Existing messages are unaffected (new columns default to null).
-- - The Seller App's Chats tab can now: attach a photo to a message, edit a
--   sent message's text, and delete a sent message (which clears its
--   content and shows "Message deleted" in its place for both sides).
-- ============================================================

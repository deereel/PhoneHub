-- Migration: group chats + message enhancements (images, edit, delete)
--
-- This finishes what the earlier session started: the Seller App JS already
-- reads/writes chat_groups, chat_group_members, and messages.group_id /
-- image_url / edited_at / deleted_at, but those tables/columns were never
-- actually created. Run this once in Supabase: Dashboard > SQL Editor >
-- New query > paste > Run. Safe to re-run.
-- ============================================================

-- 1. Group tables
create table if not exists chat_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references dealers(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists chat_group_members (
  group_id uuid not null references chat_groups(id) on delete cascade,
  dealer_id uuid not null references dealers(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, dealer_id)
);

alter table chat_groups enable row level security;
alter table chat_group_members enable row level security;

drop policy if exists "chat_groups_select_member" on chat_groups;
create policy "chat_groups_select_member" on chat_groups for select
  using (
    exists (select 1 from chat_group_members m where m.group_id = chat_groups.id and m.dealer_id = auth.uid())
    or is_admin()
  );

drop policy if exists "chat_groups_insert_own" on chat_groups;
create policy "chat_groups_insert_own" on chat_groups for insert
  with check (created_by = auth.uid());

drop policy if exists "chat_group_members_select_member" on chat_group_members;
create policy "chat_group_members_select_member" on chat_group_members for select
  using (
    exists (select 1 from chat_group_members m2 where m2.group_id = chat_group_members.group_id and m2.dealer_id = auth.uid())
    or is_admin()
  );

-- A member can add themselves (accepting an invite later, if you build that);
-- the group creator can add anyone at creation time or afterward.
drop policy if exists "chat_group_members_insert_creator_or_self" on chat_group_members;
create policy "chat_group_members_insert_creator_or_self" on chat_group_members for insert
  with check (
    dealer_id = auth.uid()
    or exists (select 1 from chat_groups g where g.id = chat_group_members.group_id and g.created_by = auth.uid())
  );

-- A member can remove themselves (leave); the creator can remove anyone.
drop policy if exists "chat_group_members_delete_self_or_creator" on chat_group_members;
create policy "chat_group_members_delete_self_or_creator" on chat_group_members for delete
  using (
    dealer_id = auth.uid()
    or exists (select 1 from chat_groups g where g.id = chat_group_members.group_id and g.created_by = auth.uid())
  );

-- 2. messages table enhancements
alter table messages add column if not exists group_id uuid references chat_groups(id) on delete cascade;
alter table messages alter column recipient_id drop not null;
alter table messages add column if not exists image_url text;
alter table messages add column if not exists edited_at timestamptz;
alter table messages add column if not exists deleted_at timestamptz;
-- body is allowed to be null now too (an image-only message has body null)
alter table messages alter column body drop not null;

alter table messages drop constraint if exists messages_target_check;
alter table messages add constraint messages_target_check
  check ((recipient_id is not null and group_id is null) or (recipient_id is null and group_id is not null));

-- 3. Replace RLS so group messages are covered too
drop policy if exists "messages_select_own" on messages;
create policy "messages_select_own" on messages for select
  using (
    sender_id = auth.uid()
    or recipient_id = auth.uid()
    or (
      group_id is not null
      and exists (select 1 from chat_group_members m where m.group_id = messages.group_id and m.dealer_id = auth.uid())
    )
  );

drop policy if exists "messages_insert_own" on messages;
create policy "messages_insert_own" on messages for insert
  with check (
    sender_id = auth.uid()
    and (
      group_id is null
      or exists (select 1 from chat_group_members m where m.group_id = messages.group_id and m.dealer_id = auth.uid())
    )
  );

-- Recipients can mark a 1:1 message read; senders can edit/soft-delete their
-- own message (body/image_url/deleted_at/edited_at) — matches what the JS
-- (saveEditMessage / confirmDeleteMessage) actually sends.
drop policy if exists "messages_update_mark_read" on messages;
drop policy if exists "messages_update_own_or_recipient" on messages;
create policy "messages_update_own_or_recipient" on messages for update
  using (sender_id = auth.uid() or recipient_id = auth.uid())
  with check (sender_id = auth.uid() or recipient_id = auth.uid());

-- 4. Realtime — group tables need to be published too so membership/new
--    groups show up live (messages is already published from the earlier migration).
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='chat_groups') then
    alter publication supabase_realtime add table chat_groups;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='chat_group_members') then
    alter publication supabase_realtime add table chat_group_members;
  end if;
end $$;

-- 5. Convenience RPC: create a group + its initial members atomically.
--    The Seller App patch below calls this as sb.rpc('create_chat_group', ...).
create or replace function create_chat_group(p_name text, p_member_ids uuid[])
returns chat_groups
language plpgsql
security definer set search_path = public
as $$
declare
  v_group chat_groups;
begin
  if p_name is null or trim(p_name) = '' then
    raise exception 'Group name is required';
  end if;
  if p_member_ids is null or array_length(p_member_ids,1) is null then
    raise exception 'Select at least one member';
  end if;

  insert into chat_groups(name, created_by) values (trim(p_name), auth.uid()) returning * into v_group;

  insert into chat_group_members(group_id, dealer_id) values (v_group.id, auth.uid())
    on conflict do nothing;
  insert into chat_group_members(group_id, dealer_id)
    select v_group.id, m from unnest(p_member_ids) as m
    where m <> auth.uid()
    on conflict do nothing;

  return v_group;
end; $$;
grant execute on function create_chat_group(text, uuid[]) to authenticated;

-- 6. Push notifications: group branch. Fans out to every member except the
--    sender, reusing the same dealer_ids-array pattern the broadcast push
--    trigger already uses.
create or replace function notify_new_message_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_url text; v_secret text; v_sender_name text; v_group_name text; v_member_ids uuid[];
begin
  select value into v_url from app_config where key='edge_function_url';
  select value into v_secret from app_config where key='edge_function_secret';
  if v_url is null then return new; end if;

  select shop_name into v_sender_name from dealers where id = new.sender_id;

  if new.group_id is not null then
    select name into v_group_name from chat_groups where id = new.group_id;
    select array_agg(dealer_id) into v_member_ids
      from chat_group_members
      where group_id = new.group_id and dealer_id <> new.sender_id;

    if v_member_ids is null or array_length(v_member_ids,1) is null then return new; end if;

    perform net.http_post(
      url := v_url,
      headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', v_secret),
      body := jsonb_build_object(
        'dealer_ids', to_jsonb(v_member_ids),
        'title', coalesce(v_group_name,'Group chat') || ' — ' || coalesce(v_sender_name,'a dealer'),
        'body', left(coalesce(new.body,'📷 Photo'), 120),
        'url', './#tab=chats', 'type', 'message'
      )
    );
  else
    perform net.http_post(
      url := v_url,
      headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', v_secret),
      body := jsonb_build_object(
        'dealer_id', new.recipient_id,
        'title', 'New message from ' || coalesce(v_sender_name, 'a dealer'),
        'body', left(coalesce(new.body,'📷 Photo'), 120),
        'url', './#tab=chats', 'type', 'message'
      )
    );
  end if;
  return new;
end; $$;

drop trigger if exists trg_notify_new_message_push on messages;
create trigger trg_notify_new_message_push after insert on messages
for each row execute function notify_new_message_push();

-- ============================================================
-- After running this:
-- - chat_groups / chat_group_members exist with RLS matching the rest of the schema.
-- - messages supports group rows (group_id set, recipient_id null) as well as
--   the existing 1:1 rows, plus image_url/edited_at/deleted_at for the
--   attach-photo/edit/delete features already in the Seller App JS.
-- - New group messages push to every member except the sender.
-- - Apply the JS patch (group_chat_and_typing_patch.md) so the UI can
--   actually create a group and render a group thread — the RPC and tables
--   alone don't do anything without it.
-- ============================================================

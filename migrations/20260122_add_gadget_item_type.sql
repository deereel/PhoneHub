-- Migration: add Gadget as a valid item type in inventory
-- Run this in your Supabase SQL Editor if you already have an existing database.

alter table inventory drop constraint if exists inventory_item_type_check;
alter table inventory add constraint inventory_item_type_check check (item_type in ('Phone','Laptop','Gadget'));

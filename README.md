# PhoneHub Pro

Business management platform for Computer Village phone dealers — inventory, sales, profit calculator, and a shared dealer network, backed by Supabase.

## Structure

- `/seller/` — Seller App (dealer registration, inventory, bulk stock import, sales, dealer network, admin oversight)
- `/customer/` — Customer App (shop browsing, phone requests, warranty lookup)
- `schema.sql` — Supabase/Postgres schema. Run this once in your Supabase project's SQL Editor before using the apps. (Already includes optional-IMEI support — you do NOT need `migration_optional_imei.sql` on a fresh project; that file is only for upgrading an older deployment.)
- `SUPABASE_SETUP_GUIDE.md` — step-by-step setup instructions.

## Live URLs (once GitHub Pages is enabled)

- Landing page: `https://<your-username>.github.io/<repo-name>/`
- Seller App: `https://<your-username>.github.io/<repo-name>/seller/`
- Customer App: `https://<your-username>.github.io/<repo-name>/customer/`

## Updating the apps

Both apps are single static HTML files. To ship a change: edit the file, commit, push — GitHub Pages redeploys automatically within a minute or two.

## What's new in this package

- **Bulk stock import** ("📋 Paste stock list" button on the Inventory tab of the Seller App) — dealers can paste their existing WhatsApp/notes-style stock lists (e.g. `Ip14 pro 128–635k`) and the app parses model, storage, and price automatically, with a review step before importing. Cost price is left blank on import since these lists only show selling price — remind dealers to fill that in per phone afterward so profit numbers are accurate.

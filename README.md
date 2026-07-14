# PhoneHub Pro

Business management platform for Computer Village phone dealers — inventory, sales, profit calculator, and a shared dealer network, backed by Supabase.

## Structure

- `/seller/` — Seller App (dealer registration, inventory, sales, dealer network, admin oversight)
- `/customer/` — Customer App (shop browsing, phone requests, warranty lookup)
- `schema.sql` — Supabase/Postgres schema. Run this once in your Supabase project's SQL Editor before using the apps.
- `SUPABASE_SETUP_GUIDE.md` — step-by-step setup instructions.

## Live URLs (once GitHub Pages is enabled)

- Seller App: `https://<your-username>.github.io/<repo-name>/seller/`
- Customer App: `https://<your-username>.github.io/<repo-name>/customer/`

## Updating the apps

Both apps are single static HTML files. To ship a change: edit the file, commit, push — GitHub Pages redeploys automatically within a minute or two.

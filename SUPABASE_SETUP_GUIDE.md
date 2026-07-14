# PhoneHub Pro — Supabase Setup Guide
### Real multi-tenant database, free tier, ready for your first 10–50 dealers

---

## Step 1 — Create your Supabase project

1. Go to [supabase.com](https://supabase.com) → sign up (free) → **New project**.
2. Pick a name (e.g. "phonehub-pro"), a database password (save it somewhere), and a region close to Nigeria (e.g. an EU region is usually the lowest latency option currently offered).
3. Wait ~2 minutes for it to provision.

## Step 2 — Run the schema

1. In your project, open the **SQL Editor** (left sidebar).
2. Click **New query**, paste in the entire contents of **schema.sql**, and click **Run**.
3. You should see a series of "CREATE TABLE / CREATE POLICY / CREATE VIEW" success messages with no errors. This creates every table, security rule, and the two special database functions (`sell_phone`, `lookup_my_purchases`) that both apps depend on.

## Step 3 — Turn off email confirmation (recommended for testing)

By default, Supabase requires users to click an email confirmation link before they can log in. For fast testing with your first dealers, turn this off:

1. **Authentication → Providers → Email**.
2. Turn off **"Confirm email"**.
3. Save.

(You can turn this back on later once you want production-grade signups.)

## Step 4 — Get your API keys

1. **Settings → API**.
2. Copy the **Project URL** (looks like `https://xxxxx.supabase.co`) and the **anon public** key (a long string starting with `eyJ...`). Do NOT use the `service_role` key in the apps — that key bypasses all security rules and must never go in client-facing code.

## Step 5 — Connect both apps

1. Open the **Seller App** — first launch asks for these two values. Paste them in and click Connect.
2. You'll land on a Register/Log in screen. **Register your own shop first** — this is how you'll test as a dealer.
3. Open the **Customer App** — it asks for the same two values once. After that, it shows a shop picker listing every registered dealer.

## Step 6 — Make yourself admin

1. After registering in the Seller App, go back to Supabase's **SQL Editor** and run:
   ```sql
   update dealers set is_admin = true where shop_slug = 'your-shop-slug-here';
   ```
   (Find your exact `shop_slug` by running `select shop_name, shop_slug from dealers;` first.)
2. Refresh/re-log into the Seller App — you'll now see an **Admin** tab showing every dealer, their stock counts, and total platform revenue.

## Everyday use

- **Each dealer registers their own account** — their inventory, sales, and customer requests are automatically private to them (enforced by the database itself, not just app-level logic).
- **Dealer Network tab → Search stock** shows every registered dealer's in-stock phones (price, model, condition) so any dealer can find who has what — without ever seeing each other's cost prices.
- **Broadcasts** are visible to every dealer instantly — no WhatsApp groups, no ban risk.
- **Customer App** — anyone who picks a shop sees only that shop's real-time catalog; submitting a request writes straight into that dealer's Seller App "Asks" tab. "My purchases" searches across *all* shops by phone number, so a customer only needs to remember their own number, not which shop they bought from.

## Cost & limits at this stage

Supabase's free tier includes 500MB database storage and 50,000 monthly active users — far beyond what 10–50 dealers and their customers will use. You will not need a paid plan until you're seeing real scale (many hundreds of dealers or heavy daily traffic), at which point upgrading is a plan change, not a rebuild.

## What's next (Phase 4 ideas, once this is proven)

- WhatsApp/SMS delivery for warranty reminders and broadcast alerts (needs a paid messaging API — Meta Cloud API or Twilio — this is the one piece that genuinely can't be free)
- Invoice/receipt PDF generation
- A dealer reputation/verification layer (fulfillment rate, response time) now that broadcasts have real responders
- Paid plans / monetization once dealers are asking to pay


Future plan

The bucket refills roughly every hour. If you've only tested with 2 real signups but tried a few times each (typos, password-too-short errors, etc.), those failed attempts count too. Waiting ~30–60 minutes usually clears it.
For the real fix once you're ready to onboard actual dealers: set up free custom SMTP so you're no longer using Supabase's shared/testing email service at all. This removes the 2/hour cap entirely (limits become whatever your SMTP provider allows).

Resend (free tier: 3,000 emails/month, no credit card) or Brevo are both good, free, and take about 2 minutes.
Configure it under Authentication → Settings → SMTP Settings in your Supabase dashboard.
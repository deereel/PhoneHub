// PhoneHub Pro — send-push Edge Function
//
// Receives a small JSON payload from a Postgres trigger (or the daily cron check)
// and delivers it as a real Web Push notification to every subscribed device for
// the relevant dealer(s). This is what makes the alert show up even if the
// Seller App isn't open.
//
// Deploy with:  supabase functions deploy send-push --no-verify-jwt
// (--no-verify-jwt because this is called by Postgres via pg_net, not a logged-in user)
//
// Required secrets (set with `supabase secrets set NAME=value`):
//   VAPID_PUBLIC_KEY       — same value pasted into seller/index.html
//   VAPID_PRIVATE_KEY      — keep this one secret, never put it in client code
//   VAPID_SUBJECT          — e.g. mailto:you@example.com
//   WEBHOOK_SECRET         — any random string; must match app_config.edge_function_secret
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY — usually already present by default in Edge Functions

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY") || "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:admin@example.com";
const WEBHOOK_SECRET = Deno.env.get("WEBHOOK_SECRET") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

Deno.serve(async (req: Request) => {
  try {
    if (WEBHOOK_SECRET) {
      const got = req.headers.get("x-webhook-secret");
      if (got !== WEBHOOK_SECRET) {
        return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
      }
    }

    const payload = await req.json();
    const { type, dealer_id, exclude_dealer_id, title, body, url, tag } = payload || {};

    let query = supabase.from("push_subscriptions").select("*");
    if (dealer_id) query = query.eq("dealer_id", dealer_id);
    else if (exclude_dealer_id) query = query.neq("dealer_id", exclude_dealer_id);
    else {
      return new Response(JSON.stringify({ error: "no dealer_id or exclude_dealer_id given" }), { status: 400 });
    }

    const { data: subs, error } = await query;
    if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

    const notifPayload = JSON.stringify({
      title: title || "PhoneHub Pro",
      body: body || "",
      url: url || "./",
      type: type || "alert",
      tag: tag || undefined,
    });

    const results = await Promise.allSettled(
      (subs || []).map(async (s: any) => {
        try {
          await webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            notifPayload
          );
        } catch (err: any) {
          // 404/410 means the browser/device unsubscribed or the subscription is stale — clean it up.
          if (err && (err.statusCode === 404 || err.statusCode === 410)) {
            await supabase.from("push_subscriptions").delete().eq("id", s.id);
          }
          throw err;
        }
      })
    );

    const sent = results.filter((r) => r.status === "fulfilled").length;
    const failed = results.length - sent;

    return new Response(JSON.stringify({ recipients: results.length, sent, failed }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message || String(e) }), { status: 500 });
  }
});

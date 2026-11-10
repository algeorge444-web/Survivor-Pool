// Sends a pool invite by email. Only the pool's commissioner can call it.
// New people get a "you've been invited" email that signs them in and asks
// them to set a password. People who already have an account get a sign-in
// link, and the invite waits for them on their home screen.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE = (Deno.env.get("SITE_URL") ?? "").replace(/\/$/, "");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { pool_id, email } = await req.json();
    const clean = String(email ?? "").trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(clean)) return json({ error: "Enter a valid email address." }, 400);
    if (!SITE) return json({ error: "SITE_URL is not set on the server." }, 500);

    const userClient = createClient(URL_, ANON, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "Sign in first." }, 401);

    const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
    const { data: pool } = await admin.from("pools").select("id, name, commissioner_id").eq("id", pool_id).single();
    if (!pool || pool.commissioner_id !== user.id) return json({ error: "Only the commissioner can invite people." }, 403);

    const { data: already } = await admin
      .from("pool_members").select("user_id, profiles!inner(email)")
      .eq("pool_id", pool_id).eq("profiles.email", clean);
    if (already && already.length) return json({ error: "That person is already in this pool." }, 400);

    const { error: invErr } = await admin
      .from("invites")
      .upsert({ pool_id, email: clean, invited_by: user.id, accepted_at: null }, { onConflict: "pool_id,email" });
    if (invErr) throw invErr;

    const { error } = await admin.auth.admin.inviteUserByEmail(clean, {
      redirectTo: `${SITE}/`,
      data: { invited_to: pool.name },
    });
    if (!error) return json({ status: "invited" });

    // Already has an account: send a sign-in link instead.
    const anon = createClient(URL_, ANON, { auth: { persistSession: false } });
    const { error: otpErr } = await anon.auth.signInWithOtp({
      email: clean,
      options: { shouldCreateUser: false, emailRedirectTo: `${SITE}/` },
    });
    if (otpErr) throw otpErr;
    return json({ status: "existing_user" });
  } catch (e) {
    return json({ error: (e as Error).message ?? "Couldn't send the invite." }, 400);
  }
});

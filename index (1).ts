// Pulls last Saturday's and next Saturday's NHL games and scores from the
// public NHL API, plus win odds from The Odds API (optional, free key).
// Safe to call often: odds are fetched at most once every 3 hours, and only
// in the 3 days before a Saturday, to stay inside the free odds quota.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const ODDS_KEY = Deno.env.get("ODDS_API_KEY") ?? "";
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const NAME_TO_ABBR: Record<string, string> = {
  "Anaheim Ducks": "ANA", "Boston Bruins": "BOS", "Buffalo Sabres": "BUF", "Calgary Flames": "CGY",
  "Carolina Hurricanes": "CAR", "Chicago Blackhawks": "CHI", "Colorado Avalanche": "COL",
  "Columbus Blue Jackets": "CBJ", "Dallas Stars": "DAL", "Detroit Red Wings": "DET", "Edmonton Oilers": "EDM",
  "Florida Panthers": "FLA", "Los Angeles Kings": "LAK", "Minnesota Wild": "MIN", "Montreal Canadiens": "MTL",
  "Montréal Canadiens": "MTL", "Nashville Predators": "NSH", "New Jersey Devils": "NJD",
  "New York Islanders": "NYI", "New York Rangers": "NYR", "Ottawa Senators": "OTT", "Philadelphia Flyers": "PHI",
  "Pittsburgh Penguins": "PIT", "San Jose Sharks": "SJS", "Seattle Kraken": "SEA", "St. Louis Blues": "STL",
  "St Louis Blues": "STL", "Tampa Bay Lightning": "TBL", "Toronto Maple Leafs": "TOR", "Utah Mammoth": "UTA",
  "Utah Hockey Club": "UTA", "Vancouver Canucks": "VAN", "Vegas Golden Knights": "VGK",
  "Washington Capitals": "WSH", "Winnipeg Jets": "WPG",
};

const etDate = (d: Date) => d.toLocaleDateString("en-CA", { timeZone: "America/New_York" });
const addDays = (iso: string, n: number) => {
  const d = new Date(iso + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const statusOf = (s: string) =>
  s === "FINAL" || s === "OFF" ? "final" : s === "LIVE" || s === "CRIT" ? "live" : "scheduled";

async function syncSchedule(date: string) {
  const r = await fetch(`https://api-web.nhle.com/v1/schedule/${date}`);
  if (!r.ok) throw new Error(`NHL schedule ${r.status}`);
  const j = await r.json();
  const day = (j.gameWeek ?? []).find((d: { date: string }) => d.date === date);
  const games = (day?.games ?? []).filter((g: { gameType: number }) => g.gameType === 2 || g.gameType === 3);
  if (!games.length) return 0;
  const rows = games.map((g: any) => {
    const status = statusOf(g.gameState);
    const a = g.awayTeam.score ?? null, h = g.homeTeam.score ?? null;
    return {
      id: g.id,
      game_date: date,
      start_time: g.startTimeUTC,
      away: g.awayTeam.abbrev,
      home: g.homeTeam.abbrev,
      status,
      away_score: a,
      home_score: h,
      winner: status === "final" && a != null && h != null ? (a > h ? g.awayTeam.abbrev : g.homeTeam.abbrev) : null,
      updated_at: new Date().toISOString(),
    };
  });
  const { error } = await admin.from("games").upsert(rows, { onConflict: "id" });
  if (error) throw error;
  return rows.length;
}

const implied = (price: number) => (price < 0 ? -price / (-price + 100) : 100 / (price + 100));

async function syncOdds(date: string) {
  if (!ODDS_KEY) return "no ODDS_API_KEY set";
  const { data: games } = await admin.from("games").select("id, away, home, start_time, status, odds_updated_at")
    .eq("game_date", date);
  if (!games?.length) return "no games";
  const upcoming = games.filter((g) => g.status === "scheduled" && Date.parse(g.start_time) > Date.now());
  if (!upcoming.length) return "games already started";
  const first = Math.min(...upcoming.map((g) => Date.parse(g.start_time)));
  if (first - Date.now() > 72 * 3600e3) return "too early for odds";
  const last = Math.max(...games.map((g) => (g.odds_updated_at ? Date.parse(g.odds_updated_at) : 0)));
  if (Date.now() - last < 3 * 3600e3) return "odds are fresh";

  const r = await fetch(
    `https://api.the-odds-api.com/v4/sports/icehockey_nhl/odds/?regions=us&markets=h2h&oddsFormat=american&apiKey=${ODDS_KEY}`,
  );
  if (!r.ok) return `odds api ${r.status}`;
  const events = await r.json();
  let updated = 0;
  for (const ev of events) {
    const away = NAME_TO_ABBR[ev.away_team], home = NAME_TO_ABBR[ev.home_team];
    if (!away || !home || etDate(new Date(ev.commence_time)) !== date) continue;
    let pa = 0, ph = 0, n = 0;
    for (const b of ev.bookmakers ?? []) {
      const m = (b.markets ?? []).find((x: any) => x.key === "h2h");
      const oa = m?.outcomes?.find((o: any) => o.name === ev.away_team);
      const oh = m?.outcomes?.find((o: any) => o.name === ev.home_team);
      if (!oa || !oh) continue;
      const ia = implied(oa.price), ih = implied(oh.price);
      pa += ia / (ia + ih); ph += ih / (ia + ih); n++;
    }
    if (!n) continue;
    const g = upcoming.find((x) => x.away === away && x.home === home);
    if (!g) continue;
    await admin.from("games").update({
      away_pct: Math.round((pa / n) * 1000) / 10,
      home_pct: Math.round((ph / n) * 1000) / 10,
      odds_updated_at: new Date().toISOString(),
    }).eq("id", g.id);
    updated++;
  }
  return `odds updated for ${updated} games`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const today = etDate(new Date());
    const dow = new Date(today + "T12:00:00Z").getUTCDay();
    const nextSat = addDays(today, (6 - dow + 7) % 7);
    const lastSat = addDays(nextSat, -7);
    const counts = { [lastSat]: await syncSchedule(lastSat), [nextSat]: await syncSchedule(nextSat) };
    const odds = await syncOdds(nextSat);
    return json({ ok: true, games: counts, odds });
  } catch (e) {
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});

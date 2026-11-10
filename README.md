# Survivor Pools — setup guide

Survivor Pools is an NHL Saturday survivor pool site. Anyone can create an account with their email and password, start their own pool, and invite players by email. Each pool's creator is its commissioner: they set the rules, invite people, and are the only one who can add or give back strikes.

It runs on two free services:

- **GitHub** stores the code and hosts the website with GitHub Pages.
- **Supabase** handles logins, the database, and sending invite emails.

Plan on about 30–45 minutes the first time. You don't need to know how to code, but you'll copy and paste a few things.

## What's in the folder

| File | What it does |
|---|---|
| `docs/index.html` | The whole website (GitHub Pages serves this folder) |
| `supabase/schema.sql` | Creates the database and its security rules |
| `supabase/functions/send-invite/` | Emails invites |
| `supabase/functions/sync-games/` | Pulls Saturday games, scores and odds |
| `supabase/cron.sql` | Runs the game sync automatically |
| `supabase/config.toml` | Function settings used when deploying |
| `.github/workflows/deploy-functions.yml` | Optional: deploys the functions from GitHub automatically |

## 1. Create the Supabase project

1. Sign up at **supabase.com** and click **New project**. Pick any name and a database password (save it somewhere).
2. When it's ready, go to **SQL Editor → New query**, paste everything from `supabase/schema.sql`, and click **Run**. You should see "Success".
3. Go to **Project Settings → API**. Copy two things:
   - **Project URL** (looks like `https://abcd1234.supabase.co`)
   - **anon public** key (labelled "anon" or "publishable")

## 2. Put the code on GitHub

1. Sign up at **github.com** and click **New repository**. Name it `survivor-pools`, choose **Public**, and click **Create repository**.
2. On the new repository page, click **uploading an existing file**. Unzip this project on your computer, open the `survivor-pools` folder, select everything inside it, and drag it onto the page. Click **Commit changes**.
3. Check that the `.github` folder came through. Mac and Windows hide folders starting with a dot, so drag-and-drop sometimes skips it. It's only needed for step 4's automatic option, so you can skip it if you'll deploy the functions by hand.

Your Supabase anon key will be visible in a public repository. That's fine and expected: it's designed to be public, and the database's security rules protect everything. Never put the **service_role** key or your odds API key in the repository.

## 3. Turn on the website

1. In `docs/index.html` on GitHub, click the pencil icon to edit. Near the top of the second `<script>` section, replace:
   - `https://YOUR-PROJECT-REF.supabase.co` with your Project URL
   - `YOUR-ANON-PUBLIC-KEY` with your anon key

   Click **Commit changes**.
2. Go to the repository's **Settings → Pages**. Under **Build and deployment**, set **Source** to **Deploy from a branch**, choose the **main** branch and the **/docs** folder, and click **Save**.
3. After a minute or two, the page shows your site's address, like `https://your-username.github.io/survivor-pools/`. Every time you change a file in `docs`, the site updates on its own.
4. In Supabase, go to **Authentication → URL Configuration**:
   - **Site URL**: your GitHub Pages address, including `/survivor-pools/`
   - **Redirect URLs**: add `https://your-username.github.io/survivor-pools/**`

   This makes confirmation, invite and password-reset emails send people back to your site.

## 4. Set up invites and game syncing

These two functions run on Supabase's servers. First, add their secrets in Supabase under **Edge Functions → Secrets**:

- `SITE_URL` = your GitHub Pages address, like `https://your-username.github.io/survivor-pools`
- `ODDS_API_KEY` = your key from step 5 (optional)

Then deploy the functions one of two ways.

**Option A: automatically from GitHub (recommended).** GitHub redeploys the functions whenever you change them.

1. In Supabase, open your account menu → **Access Tokens** and create a token.
2. In your GitHub repository, go to **Settings → Secrets and variables → Actions → New repository secret** and add:
   - `SUPABASE_ACCESS_TOKEN` = the token
   - `SUPABASE_PROJECT_REF` = the part of your Project URL before `.supabase.co`
3. Go to the **Actions** tab, choose **Deploy Supabase functions**, and click **Run workflow**. A green check means both functions are live.

**Option B: by hand in the browser.**

1. In Supabase go to **Edge Functions → Deploy a new function → Via editor**.
2. Name it `send-invite`, paste the contents of `supabase/functions/send-invite/index.ts`, and deploy.
3. Do the same for `sync-games`. **Before deploying it, turn off "Verify JWT"** in its settings so the automatic timer can call it.

## 5. Win percentages (optional, free)

Games and scores come from the NHL's public schedule, with no key needed. Win percentages come from betting odds at **the-odds-api.com**:

1. Sign up for the free plan (500 requests a month).
2. Copy your API key into the `ODDS_API_KEY` secret from step 4.

The app only checks odds every 3 hours in the 3 days before a Saturday, about 70 requests a month. That keeps you well inside the free limit. The percentages are averaged across sportsbooks with the bookmaker's cut removed.

Without a key, everything else works and games just show "Odds soon".

## 6. Turn on automatic syncing

1. In Supabase go to **Database → Extensions** and turn on **pg_cron** and **pg_net**.
2. Open `supabase/cron.sql`, replace `YOUR-PROJECT-REF` with the part of your Project URL before `.supabase.co`, and run it in the SQL Editor.

Games, scores and odds now refresh every 20 minutes. Commissioners also get a **Refresh games and odds** button.

## 7. Email sending (important for real use)

Supabase's built-in email is for testing only. It sends just a few emails per hour, which will block invites once you have more than a handful of players.

For real use, connect a free email service:

1. Sign up at **resend.com** (free for 3,000 emails a month) and verify a domain you own. If you don't have a domain, one costs about $15 a year from any registrar.
2. In Supabase go to **Authentication → Emails → SMTP Settings**, turn on custom SMTP, and enter Resend's SMTP details.

You can also edit the wording of the invite email under **Authentication → Emails → Templates → Invite user**.

## Try it

1. Open your site, click **Create an account**, confirm your email, and sign in.
2. Create a pool. You'll land on the Commissioner tab.
3. Invite a second email address you own and accept the invite from that inbox.
4. On the Commissioner tab, press **Refresh games and odds** to load this Saturday's games.

## How the rules work

- Each player has the number of lives the commissioner sets (1–5). A loss, including in overtime or a shootout, is a strike. With the setting on, a missed Saturday is also a strike.
- Each team can be picked once or twice per season, depending on the pool setting.
- Picks lock either when the player's chosen game starts, or for everyone at the first puck drop of the day.
- Other players' picks stay hidden until they lock, unless the commissioner chooses to show them right away.
- Only the commissioner can add or give back strikes, remove players, change settings, or delete the pool. These rules are enforced by the database itself, not just hidden in the page, so players can't get around them.
- A pool only counts Saturdays from the day it was created.

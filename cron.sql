-- Runs the sync-games function every 20 minutes so games, scores and odds
-- stay current without anyone pressing a button.
-- 1. Supabase > Database > Extensions: turn on pg_cron and pg_net.
-- 2. Replace pqhwctrxhmdrvkkhbzbn below (from your project URL), then run this in the SQL Editor.

select cron.schedule(
  'sync-nhl-games',
  '*/20 * * * *',
  $$
  select net.http_post(
    url := 'https://pqhwctrxhmdrvkkhbzbn.supabase.co/functions/v1/sync-games',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb
  );
  $$
);

-- To stop it later:  select cron.unschedule('sync-nhl-games');

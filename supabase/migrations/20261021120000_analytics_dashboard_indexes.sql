-- Index for the Control Center's "sessions started in the last 30 days"
-- count and daily activity read. Additive only: no data, policy or grant
-- changes. The dashboard works without it, just with a sequential scan.
create index if not exists orvix_analytics_sessions_started_idx
  on public.orvix_analytics_sessions (started_at desc);

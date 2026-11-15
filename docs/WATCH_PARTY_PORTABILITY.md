# Orvix Watch Party: free-first hosting, backups and exit plan

**Status:** planning and operational guardrails only. No self-hosted service, backup job, traffic alarm, migration or failover has been deployed by this document. Watch Party remains off by default. This document belongs to the draft PR #97 staging work and must not be treated as production readiness.

## Decision

- **Now:** use the existing managed Supabase Free project for Orvix; test Watch Party against the separate **Orvix Watch Party Test** project. Never point experiments at production.
- **If usage approaches quotas:** first reduce avoidable traffic and apply admission control. Do not automatically upgrade or silently switch to aggressive polling.
- **Longer-term exit:** rehearse a **self-hosted Supabase** restore and, if only room synchronization is expensive, evaluate moving Watch Party to a dedicated service without moving all Orvix accounts.
- **Never require a paid plan as the only recovery route.** Self-hosting still costs money (server, traffic, backups) or requires a reliable donated host and operator.

## What is portable today

The Flutter interface `WatchPartyBackend` and `WatchPartyChannel` separates the UI and synchronization logic from `SupabaseWatchPartyBackend`. That is a useful seam for replacing the transport. It **does not** make the entire backend provider-independent.

| Component | Currently coupled to | Exit work |
| --- | --- | --- |
| Room and chat state | PostgreSQL functions, tables, locks and RLS | Keep schema with self-hosted Supabase, or implement an equivalent transactional room service |
| Realtime | Supabase private Broadcast, `realtime.send`, topic RLS | Self-hosted Realtime or authenticated WebSocket transport; re-test authorization, order and reconnect |
| Identity | Supabase Auth / `auth.uid()` | Self-host Auth or establish an explicit token-verification and account mapping strategy |
| Flutter UI, drift logic | `WatchPartyBackend` interface | Plug in a new adapter and rerun sync and device tests |
| Test-build configuration | Build-time Supabase URL and publishable key | Preserve strict production/test isolation; document how a future endpoint is selected |

Do not ship a second implementation until the current MVP passes authenticated real-project and two-device tests. Avoid creating a dual-write database or copying user credentials to a speculative provider.

## Managed free-plan budgets

Current official docs (recheck before a release): free tier includes **200 peak Realtime connections**, **2 million Realtime messages per month**, **500 MB database quota** and **50,000 monthly active Auth users**. The first constraint reached depends on usage; Realtime connections are shared with other app features. Approximate numbers of full 10-person rooms are not reliable capacity guarantees.

**Internal early-warning targets (not Supabase hard limits):**

| Signal | Review at | Action |
| --- | --- | --- |
| Concurrent Realtime connections | 140 (70% of 200) | Check room admissions, reconnect churn and other app consumers |
| Realtime deliveries per month | 1.4 million (70% of 2 million) | Examine events per room, batching and chat volume |
| DB size | 350 MB (70% of 500 MB) | Check retention, indexes and unrelated app data |
| Unexpected API/Edge/egress growth | 50–70% of each current quota | Investigate usage before changing plans |

These targets are **not automated**. Set up measurements from the project Usage dashboard and trusted read-only database metrics before claiming alerts are active. Avoid logging message bodies, tokens, passwords, invite codes or participant identities in a public monitoring system.

### Congestion behaviour

- Keep current room cap (10), short retention (12 hours maximum / 30 minutes idle) and bounded chat (200).
- Realtime interruptions can use the existing bounded polling fallback, but **many clients polling every 3 seconds can overload Postgres**. Before scale, add exponential backoff with jitter, a server-side concurrency limit, and user-visible "room temporarily unavailable" / retry states. Prefer refusing new rooms to destabilizing all Orvix sessions.
- Monitor active rooms, participant heartbeats, RPC latency/error rate, message delivery, database load and Realtime quota. Do not equate registered accounts with concurrent Watch Party connections.
- A degraded transport must never skip server-side participant limits, host authorization or RLS; never fall back to a public room channel.

## Backups: a plan is not a backup

**Managed Supabase Free does not include automatic daily database backups.** The production database currently has no backup job created by this plan. **Treat that as an open production risk.**

1. Set up a separate, least-privilege operational procedure to export the **production database** (not an empty staging database) on an agreed schedule, initially daily if operationally feasible. Use the supported Supabase CLI `db dump` workflow, including roles, schema and data as described in the official migration guide. Carefully review privileges: full account-related dumps contain private data and password hashes.
2. Keep database passwords and connection URLs out of GitHub repositories, CI logs and issue comments. Use an approved local or secured backup runner, encrypt backups, maintain offline/off-site copies with restricted access and a documented retention period, and securely delete expired copies.
3. Storage objects are **not** included in a Postgres dump. Inventory buckets and plan a separate Storage-object export if Orvix uses them. Also inventory Edge Functions, secrets (without exporting raw secrets into docs), Auth/SMTP/OAuth settings, provider integrations and necessary update URLs.
4. A backup is not verified until an authorized **restore rehearsal** to a disposable isolated target succeeds. Compare data counts, functions, RLS grants and application-level sign-in; never use production as the restore target.
5. Document recovery point objective (RPO), recovery time objective (RTO), schedule owner, last successful encrypted backup and last restore rehearsal. None are established yet.
6. Watch Party rooms/chat expire quickly; permanent Orvix accounts, sync data and settings must be prioritized over ephemeral rooms during disaster recovery. Limit retention of room chat per the privacy policy.

Helpful official documentation:
- https://supabase.com/docs/guides/self-hosting/restore-from-platform
- https://supabase.com/docs/guides/platform/backups
- https://supabase.com/docs/guides/self-hosting

## Exit rehearsal: managed to self-hosted Supabase

Do this first on a disposable environment, never on the live app:

1. Provision a supported self-hosted Supabase Docker deployment with tested persistent storage, TLS, monitored resource use and restricted admin access. Self-hosted Supabase is **not** identical to managed Supabase; it has no managed backup or PITR.
2. Follow the official **Restore a Platform Project to Self-Hosted** guide for database roles/schema/data. Confirm supported extensions and version compatibility. Test `auth.users`, RLS and SECURITY DEFINER function privileges with real authenticated and unauthenticated requests.
3. Reconfigure **Auth providers, SMTP, JWT/API keys and redirect URLs**; tokens signed with the old project's keys may require all clients to sign in again. Plan a user-facing notice and a safe way to update client configuration.
4. Re-deploy necessary Edge Functions, transfer Storage objects separately, restore encrypted credential dependencies using their supported procedures, and configure Realtime private-channel authorization.
5. Test the entire Watch Party flow: 10-way join race, host-only commands, chat permissions, blocked former members, reconnection, clock drift, TV QR sign-in and disabled-public-channel rules.
6. Run a two-device soak/load exercise with a measured budget. Confirm backups and restoration on the new server before cutover.
7. Only after a successful rehearsal: plan versioned client endpoint distribution, staged rollout, rollback, maintenance window and user communication. Do not hard-code an abrupt endpoint cutover or silently move accounts.

**Cheaper partial migration option:** retain managed Auth/database but replace only Watch Party room signaling with a small separately hosted authenticated service behind the existing `WatchPartyBackend` seam. This requires token validation, authoritative state/locking, rate limiting and a costed operation plan; it is not yet implemented and must not be confused with a zero-cost guarantee.

## Release gates

- [ ] Test project schema and private Realtime verified
- [ ] Test build artifacts generated using staging keys only
- [ ] Real authenticated two-device test succeeds, including reconnect
- [ ] Privacy policy updated for room names, chat and retention
- [ ] Monitoring and admission-control policy implemented and verified
- [ ] Production encrypted backup exists and isolated restore rehearsal passes
- [ ] An operator, contact path and migration/rollback runbook are recorded
- [ ] Explicit owner approval before any production migration, feature enablement, public app release or paid service

This plan is intentionally separate from the core Watch Party implementation to avoid spending limited development effort on an unneeded second backend before the MVP works.

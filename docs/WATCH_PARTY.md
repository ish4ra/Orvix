# Watch Party

Watch a movie or episode in sync with up to nine other people, with room
chat. Each person plays the title from **their own source**; the room only
shares what is being watched, the play position and chat.

Status: **phase 1, off by default.** The code is in the app but compiled out
unless a build defines `ORVIX_WATCH_PARTY`, and the backend migration has not
been applied to any Supabase project. Nothing here has been tested against a
live Supabase project or on real devices yet; see
[What is verified](#what-is-verified) and
[Device testing](#device-testing-before-enabling).

## What it does

- Private rooms: create one, share the eight-character invite code, up to 10
  people including the host.
- Host and participants. The host's play, pause and seek apply to everyone.
- Presence: who is here, who has the title open ("Ready"), who is buffering,
  who dropped.
- Chat in the lobby and, on touch and desktop, over the video.
- Recovery: short network drops, missed events, a host who disappears, a
  removed participant.

What never leaves the device: stream URLs, magnets, source or provider names,
debrid/cloud credentials and tokens, file names. A room stores a catalog id
(for example `tt1375666`), season and episode numbers, a title string, a
position and chat text.

## How people use it

1. Settings → Watch Party (shown only when the feature is compiled in). An
   Orvix account is required.
2. **Host:** Create room, share the code, then open any movie or episode and
   press play as usual. That title becomes the room's title.
3. **Everyone else:** Join with the code. The lobby shows the title; "Open
   title" opens its page. Pick a source and press play. The player jumps to
   the room's position and follows it.
4. In the player a small pill shows the sync state. On phones, tablets and
   desktop, tapping it opens chat. On Android TV the pill is display only;
   chat is written in the lobby.

Rules a viewer will notice:

- Only the host's play, pause and seek change the room. A participant who
  seeks is brought back; one who presses play while the room is paused is
  paused again.
- A participant may pause locally. Their player is left paused until they
  press play (it then rejoins the room's position) or the host plays, pauses
  or seeks.
- Playback speed is held at 1× while in a room.
- A host who closes the player pauses the room where they were.
- A host who starts a different title (for example the next episode) moves
  the room to it. Everyone else is told and opens it themselves.

## Architecture

```text
 player screen ──reads/commands──▶ WatchPartyPlayerAdapter (mpv | ExoPlayer)
                                            ▲
 WatchPartyScreen / overlay ◀──listens── WatchPartySession ──▶ WatchPartyBackend
                                            │  ▲                    │
                                 orders by  │  │ events             │ RPC
                                 sequence   ▼  │                    ▼
                                      Realtime private       watch_party_* functions
                                      Broadcast topic  ◀──── (PostgreSQL, RPC-only tables)
                                                     realtime.send()
```

| Piece | File |
|---|---|
| Feature flag | `lib/services/watch_party/watch_party_feature.dart` |
| Room session: ordering, drift correction, reconnect, chat | `lib/services/watch_party/watch_party_session.dart` |
| Player adapters | `lib/services/watch_party/watch_party_player_adapter.dart` |
| Server clock estimate | `lib/services/watch_party/watch_party_clock.dart` |
| Backend boundary and Supabase implementation | `watch_party_backend.dart`, `supabase_watch_party_backend.dart` |
| Entry point used by players and screens | `lib/services/watch_party/watch_party_service.dart` |
| Screen, chat, overlay, Settings entry | `lib/screens/watch_party_screen.dart`, `lib/widgets/watch_party_*.dart` |
| Database | `supabase/migrations/20261112120000_create_watch_party.sql` |

### Authoritative state and ordering

The room row holds one playback state: *at server time `at_ms` the position
was `position_ms`, and playback was or was not running.* Every accepted
change gets the next `state_seq` while the room row is locked, so all changes
have one order.

- Clients apply a state only if its number is higher than the one they have.
  A duplicate, a late arrival or an out-of-order pair is therefore harmless,
  whether it comes from Realtime or from a heartbeat reply.
- Host commands carry a per-host `client_seq`. A command that arrives after a
  newer one was accepted, or twice, is ignored by the database.
- A command that describes the state the room is already in is not announced.
- Roster and chat have their own sequence numbers and are handled the same
  way. A chat message carries a client-chosen id, so a retried send is one
  message.

### Clock

Every room call returns the server time. The client keeps the sample with the
shortest round trip of the last eight and reads positions against that
estimate, so everyone uses the same clock. The local side is a monotonic
timer; changing the device clock has no effect.

### Following the room

A player is never hooked. While a room is joined, the session reads the
player twice a second through a `WatchPartyPlayerAdapter` and compares it with
where the room says playback should be.

| Gap to the room | Action |
|---|---|
| up to 0.35 s | nothing |
| 0.35 s to 2.5 s | play 5% faster or slower until within 0.12 s |
| over 2.5 s (1.2 s on an engine without speed control) | seek |
| any gap over 0.7 s right after the host plays, pauses or seeks | seek at once |

What prevents seeking loops and storms:

- After a seek, the session measures how far behind the player ended up and
  aims that much ahead next time (capped at 5 s), so a source that takes
  seconds to seek converges.
- The pause between two corrective seeks starts at 4 s and doubles each time
  a seek did not reach sync, up to 30 s.
- A stalled (buffering) player is not seeked.
- A participant's own actions never produce a room change, so one bad
  connection cannot move anyone else.
- A buffering participant is shown as buffering to the room after 1.5 s; the
  room keeps playing and they catch up when their player recovers.
- A host who stalls and ends up more than 2.5 s behind moves the room back to
  where they are (at most every 5 s) instead of being skipped ahead.

For the host the same readings are the *source* of room changes: a pause,
play or seek made with the player's own controls shows up in the readings and
is published. This is why no player control was modified.

### Players

| Product | Engine | Adapter | Status |
|---|---|---|---|
| Android TV (default) | Media3 ExoPlayer | `ExoWatchPartyAdapter` | Wired. Tested through the real player screen with a fake native backend. Not yet run on a TV. |
| Android Mobile (optional ExoPlayer) | Media3 ExoPlayer | same | Same code path as TV. |
| Android Mobile (default), Android TV (manual) | MPV (media_kit) | `MediaKitWatchPartyAdapter` | Wired. The adapter is a thin wrapper over the media_kit `Player`; the sync logic behind it is unit tested, the wrapper itself can only be exercised on a device. |
| Windows, macOS, iOS | MPV (media_kit) | same | Same code path. Builds are validated by CI; behaviour is untested on devices. |

Player defaults and engine routing are unchanged. With the flag off, or with
no room joined, `WatchPartyService.attachPlayer` returns null before touching
the player.

Not synchronised in phase 1:

- Videos without a catalog id (files played from a cloud drive in Clouds).
- AI Sinhala playback is not special-cased. Its preparation runs before
  playback starts, so it should behave like any other MPV playback, but that
  combination is untested.

### Presence and host hand-over

Each member sends a heartbeat every 15 s (every 3 s while Realtime is not
subscribed). There is no background job; housekeeping runs when a heartbeat
arrives:

- silent for 45 s: shown as offline;
- a **host** silent for 60 s: the longest-present online member becomes host.
  Playback is left as it is. A returning former host is a participant; the
  new host can hand the room back;
- silent for 2 minutes: the place is released (rejoining with the code
  restores it, and the app does this by itself after a long disconnect);
- a host who leaves hands over at once; the last person leaving deletes the
  room.

### Realtime use

The database sends every room event with `realtime.send()` to a **private**
Broadcast topic named after a random key stored on the room. Clients only
listen. Events: `state`, `roster`, `chat`, `closed`, `rekey`.

If Realtime is unavailable the feature still works: every heartbeat reply
carries the full state, roster and any chat after the last message the client
has. Reaction time then is the 3 s polling interval instead of immediate.

## Security model

| Property | How it is enforced |
|---|---|
| Rooms are private | Tables are RPC-only: row level security on, no policies, no privileges for `anon` or `authenticated`. Every function takes the caller from `auth.uid()`. |
| No access without an account | The `watch_party_*` functions are executable by `authenticated` only. |
| Unpredictable invite codes | 8 symbols from a 32-symbol alphabet (40 bits) drawn from the database's cryptographic generator. Joining is limited to 10 attempts per 10 minutes per account, and failed attempts count. A wrong code and an expired room look the same. |
| Ten-person limit | Checked while holding the room row lock, so simultaneous joins cannot exceed it. |
| Host-only control | Checked in the database against the room's current host. The client's own idea of who is host is never trusted. |
| No privilege escalation | Nothing a client sends names a user or a role. The host changes only by `watch_party_transfer_host` (host only), by the host leaving, or by the 60 s hand-over. |
| Only members receive events | Row level security on `realtime.messages`: SELECT for an active participant of the live room that owns the topic. There is no INSERT policy for these topics, so clients cannot send on them, and no presence policy. |
| A removed participant stops receiving | Removal replaces the room's topic key. Remaining members are told to fetch the new topic through a call only members can make. The removed account cannot rejoin that room. |
| No personal data to other members | Members see an opaque per-room participant id and the chosen display name. Account ids and emails never appear in any response or event. |
| Input validation | Display names and messages are reduced to one line; control characters and bidirectional override characters are removed (zero-width joiners are kept for Sinhala); lengths are capped (24 and 500). Media ids must match `[A-Za-z0-9:_.-]{1,64}`, so a URL cannot be stored as a title id. Positions and timestamps are clamped. |
| Abuse limits | Per account: create 6/hour, join 10/10 min, chat 8/10 s, playback 30/10 s, status 40/10 s, media 20/10 min; a plain heartbeat more often than about once a second is refused without a write. One room per account at a time. |
| Bounded storage | A room keeps at most 200 messages. Rooms live at most 12 hours and are closed after 30 minutes without activity. Closed and expired rooms are deleted with everything in them. |
| Account deletion | All watch party rows reference `auth.users` with `on delete cascade`. |
| No secrets in the client | The app uses the public key and the user's session only. No service-role key is involved anywhere in this feature. |

Known limits, to decide before enabling:

- **Anonymous sign-ins.** If the project ever enables Supabase anonymous
  sign-ins, anonymous users are `authenticated` too and could create rooms.
  Keep them disabled, or add an `is_anonymous` check to the functions first.
- **Other policies on `realtime.messages`.** A pre-existing permissive SELECT
  policy for `authenticated` would also allow listening to these topics. The
  topic name is an unguessable key that only members are given, which limits
  the exposure, but check for such policies before deploying (query below).
- **Chat moderation.** There is none beyond the host removing someone. Text
  is not filtered.
- **Privacy notice.** `PRIVACY.md` does not mention rooms yet. It should
  before the feature is enabled: a display name and chat text are stored for
  the life of a room (at most 12 hours).

## Cost on the free tier

Per room, nothing runs unless someone is in it.

- **Database writes:** one small row update per member per heartbeat (240 per
  member-hour), plus one per host action and chat message.
- **Realtime messages** (each delivery to each member counts): a two-hour
  film with five people and a lively chat is on the order of 20 state events,
  30 roster events and 200 chat messages, about 1,300 deliveries.
- **Connections:** one Realtime connection per member in a room.
- **Storage:** well under 200 KB per room at its largest, deleted when the
  room ends.

The limiting resource on a free Supabase plan is concurrent Realtime
connections. Check the project's current quota; if it is reached, new members
fall back to polling automatically rather than failing. No media relay, TURN
server or other paid infrastructure is used in phase 1.

## Deployment

Nothing in this repository deploys the backend. To enable the feature:

1. **Check for existing Realtime policies** (read-only):

   ```sql
   select policyname, cmd, roles, qual
   from pg_policies where schemaname = 'realtime' and tablename = 'messages';
   ```

2. **Apply** `supabase/migrations/20261112120000_create_watch_party.sql` to
   the project. It creates four tables, the functions and one policy on
   `realtime.messages`. It can be applied twice without harm. It does not
   touch any existing table or function.

3. **Confirm the boundary** (read-only):

   ```sql
   select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon,
          has_function_privilege('authenticated', p.oid, 'execute') as authenticated
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (p.proname like 'watch\_party\_%' or p.proname like 'orvix\_watch\_%')
   order by 1;
   ```

   `anon` must be false everywhere; `authenticated` true only for the ten
   `watch_party_*` functions and `orvix_watch_party_can_listen`.

4. **Optional: scheduled cleanup.** Creating a room already sweeps dead
   rooms. For a regular sweep enable `pg_cron` and run:

   ```sql
   select cron.schedule('orvix-watch-party-cleanup', '*/10 * * * *',
     $$select public.orvix_watch_party_cleanup(500)$$);
   ```

5. **Build a test app** with `--dart-define=ORVIX_WATCH_PARTY=true` and go
   through [Device testing](#device-testing-before-enabling).

6. Update `PRIVACY.md`, then enable the define in release builds.

To remove it again:

```sql
drop policy if exists "Watch party members receive room broadcasts" on realtime.messages;
drop table if exists public.orvix_watch_room_messages, public.orvix_watch_room_participants,
  public.orvix_watch_rooms, public.orvix_watch_rate_limits cascade;
-- then drop the public.watch_party_* and public.orvix_watch_* functions
```

## What is verified

Automated, in this repository:

| Area | Where |
|---|---|
| Room lifecycle, the ten-person limit, access control, host-only actions, state ordering and stale commands, chat rules and retention, removal and topic replacement, host hand-over, expiry and cleanup, Realtime authorization | `supabase/tests/watch_party/run.sh` (scratch PostgreSQL with a stand-in for Realtime) |
| 30 simultaneous joins, simultaneous chat, racing playback commands | `supabase/tests/watch_party/concurrency.sh` |
| Privileges of every new table and function, on top of Supabase's defaults | `supabase/tests/security/run.sh` |
| Event ordering, duplicates and late events, drift correction, seeking-loop prevention, buffering, reconnect, host-only control, title matching | `test/watch_party_sync_test.dart` |
| Wire format, clock, chat rules | `test/watch_party_models_test.dart` |
| Create/join, lobby, host controls, chat, error and recovery messages, Android TV remote navigation | `test/watch_party_screen_test.dart` |
| Feature flag, ExoPlayer screen following and driving a room, overlay, Settings entry, MPV wiring | `test/watch_party_player_wiring_test.dart` |

```sh
supabase/tests/watch_party/run.sh         "postgresql://localhost:5432/scratch"
supabase/tests/watch_party/concurrency.sh "postgresql://localhost:5432/postgres"
flutter test test/watch_party_sync_test.dart test/watch_party_models_test.dart \
             test/watch_party_screen_test.dart test/watch_party_player_wiring_test.dart
```

Not verified, and not claimed:

- Anything against a real Supabase project: the RPC round trips through
  PostgREST, `realtime.send`, private-channel authorization and the Dart
  Realtime client's subscribe/reconnect behaviour. The SQL tests use a
  stand-in that mirrors how Realtime evaluates the policy.
- Real players on real devices: actual seek latency, speed changes on
  libmpv and Media3, behaviour with slow or stalling sources, Free P2P
  startup, and how sync feels.
- The media_kit adapter wrapper (it needs libmpv).

## Device testing before enabling

Two accounts and two devices at minimum; ideally one each of Android TV,
Android phone and Windows.

1. Create on one device, join on the other. Wrong code, full room (needs 11
   accounts or a lowered limit on a test project), signed-out device.
2. Host plays a movie; participant opens the title with a **different
   source** and joins mid-film. Check the positions match within about half a
   second (pause both and compare timestamps).
3. Host: pause, play, seek forward and back, scrub while paused. Each should
   reach the participant within about a second.
4. Participant: seek (is brought back), pause (stays paused, rejoins on
   play), press play while the room is paused (is paused again), change
   playback speed (returns to 1×).
5. Throttle or briefly disable the participant's network: "Reconnecting…",
   then recovery to the room's position; chat sent meanwhile appears in
   order.
6. Kill the host app: after about a minute another member becomes host and
   can control playback. Reopen the old host: joins as a participant.
7. Remove a participant: they are dropped and cannot rejoin with the code.
8. Different cuts (for example theatrical and extended): the runtime warning
   appears for the participant.
9. Series: host finishes an episode and starts the next; participants see
   the new title and open it.
10. Each engine as host and as participant: Android TV ExoPlayer, Android
    Mobile MPV, Android Mobile ExoPlayer, Windows. A Free P2P source and a
    debrid source on each side.
11. Android TV: every control in Settings → Watch Party and the lobby with
    the DPAD only; type a name, a code and a chat message with the on-screen
    keyboard; Back from each screen.
12. Solo playback with the feature compiled in and no room joined, on every
    product: nothing looks or behaves differently.
13. Leave the app in a room for 12 hours on a test project: the room expires
    and is deleted.

## Later phases

**Phase 2 (room experience)**

- Choose the room's title from a title page before anyone plays, and a
  "start when everyone is ready" countdown.
- Invite links and a QR code on TV for joining from a phone.
- A room indicator outside Settings (navigation or a persistent pill).
- Optional "wait for buffering" and "anyone may pause" room settings.
- Reactions; chat while watching on TV; simple chat moderation.
- Synchronising videos without a catalog id by file hash.

**Phase 3 (voice)**: see below.

## Voice chat (planned, not built)

Goal: talk while watching, without paying for media relay.

- **Topology: audio-only peer-to-peer mesh.** With Opus at about 24–32 kbit/s
  a ten-person mesh is roughly 300 kbit/s up and down per person, which home
  and mobile connections handle. No SFU or media server is needed at this
  room size; one would only be justified for video or larger rooms.
- **Signalling: the existing room.** Offers, answers and ICE candidates are
  small and bursty. Add `watch_party_signal(room, to_participant, payload)`:
  it checks membership, rate limits, and sends the payload with
  `realtime.send` to a per-participant private topic, so signalling stays
  database-originated and members still cannot send on room topics. Payloads
  are size-capped and never stored.
- **NAT traversal:** public STUN first. Without TURN a minority of pairs
  (symmetric NAT, some mobile carriers) cannot connect; phase 3a ships
  without TURN and shows "voice is not available on this connection" for
  those pairs. Phase 3b adds TURN only if real usage shows the failure rate
  matters: a small self-hosted coturn with short-lived credentials issued by
  an Edge Function, or a metered provider with a free allowance. That is the
  only part with a running cost, and audio-only relaying is light.
- **Client:** `flutter_webrtc`. It adds native libraries on every platform,
  so it needs the same care as the other pinned native pieces (app size, the
  generated Android and macOS projects, iOS legacy build). Evaluate on a
  branch before committing to it.
- **Behaviour:** push-to-talk by default, with an open-mic option; platform
  echo cancellation; the film's volume is lowered while someone speaks;
  per-person mute; Android TV devices without a microphone are listen-only.
- **Privacy:** audio goes directly between members (DTLS-SRTP), is never
  recorded and never passes through Orvix. Peers learn each other's IP
  addresses, which must be stated before joining voice.

# Backend portability

Orvix keeps backend-specific code behind service/repository boundaries so the shared Flutter UI does not depend directly on one backend vendor.

## Current backend

Supabase currently provides authentication, account sync, selected server functions, and the public supporters data store.

## Portability rule

New UI and domain code should depend on an Orvix service or repository interface. Supabase SDK calls should stay inside the concrete implementation. This makes it possible to introduce another implementation later, such as a self-hosted API, PocketBase, Appwrite, or PostgreSQL-backed service, without rewriting screens.

The supporters wall is the first explicit example:

- `SupportersRepository` defines the app-facing contract.
- `SupabaseSupportersRepository` is the current implementation.
- `SupportersService.repository` is the composition point.
- `SupportersScreen` only talks to `SupportersService`.

Provider secrets for GitHub Sponsors, Ko-fi, and Buy Me a Coffee must remain server-side and must never be shipped in Windows or Android binaries.

This is an incremental architecture rule. Existing Supabase-backed account code can be migrated behind similar boundaries as it is touched, rather than risking a large rewrite during active prerelease development.

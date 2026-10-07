-- The production credentials table predates these migrations. This copy only
-- has the columns the tests need, with a foreign key that does not cascade.
create table public.orvix_user_credentials (
  user_id uuid primary key references auth.users(id),
  payload text not null,
  updated_at timestamptz not null default now()
);
alter table public.orvix_user_credentials enable row level security;

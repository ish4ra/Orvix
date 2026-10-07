alter table public.orvix_analytics_installations
  add column if not exists device_manufacturer text,
  add column if not exists device_model text,
  add column if not exists device_type text;

comment on column public.orvix_analytics_installations.device_manufacturer is
  'Privacy-safe device manufacturer reported by the app; no serial/IMEI/MAC identifiers.';
comment on column public.orvix_analytics_installations.device_model is
  'Hardware/product model string reported by the OS; no user-assigned device name.';
comment on column public.orvix_analytics_installations.device_type is
  'Broad class such as Mobile, TV, or Desktop.';

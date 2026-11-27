-- CRM WhatsApp, fase 1: captura cruda de los eventos del webhook de BuilderBot.
-- Solo el servidor (service_role) lee y escribe: RLS activo y sin políticas.
create table if not exists public.wa_eventos (
  id bigint generated always as identity primary key,
  recibido_en timestamptz not null default now(),
  payload jsonb not null
);
alter table public.wa_eventos enable row level security;

-- Token que BuilderBot manda en el encabezado x-webhook-token.
insert into public.bot_config (clave, valor)
select 'webhook_token', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
where not exists (select 1 from public.bot_config where clave = 'webhook_token');

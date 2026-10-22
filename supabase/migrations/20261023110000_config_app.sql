-- Configuración de texto de la app (lee cualquier usuario, modifica solo el admin).
-- wa_nombre_verificador: nombre con el que se presenta el verificador en las plantillas de WhatsApp ({verificador}).
create table if not exists public.config_app (
  clave text primary key,
  valor text,
  actualizado_en timestamptz not null default now(),
  actualizado_por uuid default auth.uid()
);
alter table public.config_app enable row level security;
create policy config_app_sel on public.config_app for select using ((select mi_rol()) is not null);
create policy config_app_ins on public.config_app for insert with check ((select mi_rol()) = 'admin');
create policy config_app_upd on public.config_app for update using ((select mi_rol()) = 'admin') with check ((select mi_rol()) = 'admin');
insert into public.config_app (clave, valor) values ('wa_nombre_verificador', null) on conflict (clave) do nothing;

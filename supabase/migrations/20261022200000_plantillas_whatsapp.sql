-- Plantillas de WhatsApp para escribirle al cliente desde "Por verificar".
-- Variables: {cliente} {cliente_completo} {verificador} {asesor} {codigo} {monto}. Solo el admin las modifica.
create table if not exists public.plantillas_wa (
  id bigint generated always as identity primary key,
  titulo text not null,
  texto text not null,
  orden int not null default 0,
  activo boolean not null default true,
  actualizado_en timestamptz not null default now(),
  actualizado_por uuid default auth.uid()
);
alter table public.plantillas_wa enable row level security;
create policy plantillas_wa_sel on public.plantillas_wa for select using ((select mi_rol()) is not null);
create policy plantillas_wa_ins on public.plantillas_wa for insert with check ((select mi_rol()) = 'admin');
create policy plantillas_wa_upd on public.plantillas_wa for update using ((select mi_rol()) = 'admin') with check ((select mi_rol()) = 'admin');
create policy plantillas_wa_del on public.plantillas_wa for delete using ((select mi_rol()) = 'admin');

insert into public.plantillas_wa (titulo, texto, orden) values
 ('Coordinar visita', 'Hola {cliente} 👋, le saluda {verificador} de Más Pisto. Le escribo para coordinar la visita de verificación de su solicitud. ¿Se encuentra en su domicilio el día de hoy?', 1),
 ('Pedir ubicación', 'Hola {cliente}, le saluda {verificador} de Más Pisto. ¿Me podría compartir su ubicación por WhatsApp para llegar a su domicilio? Muchas gracias.', 2),
 ('Voy en camino', 'Hola {cliente}, soy {verificador} de Más Pisto. Voy en camino a su domicilio para la verificación, llego en unos 20 minutos. ¡Gracias!', 3),
 ('No lo encontré', 'Hola {cliente}, soy {verificador} de Más Pisto. Pasé por su domicilio para la verificación pero no logré encontrarle. ¿A qué hora le puedo visitar?', 4),
 ('Verificación completada', 'Hola {cliente}, le saluda {verificador} de Más Pisto. Su verificación fue completada con éxito ✅. En breve continuamos con su desembolso. ¡Gracias por su confianza!', 5);

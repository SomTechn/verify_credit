-- Historial de notificaciones enviadas (solo lo ve el administrador).
-- La función "push" guarda una fila por persona cada vez que envía un aviso, con la fecha y hora del envío
-- y en cuántos de sus dispositivos se entregó (0 = la persona no tiene notificaciones activas).
create table if not exists public.push_historial (
  id bigserial primary key,
  enviado_en timestamptz not null default now(),
  lote uuid not null,                       -- mismo lote = mismo aviso enviado a varias personas
  user_id uuid not null references auth.users(id) on delete cascade,
  titulo text not null,
  cuerpo text,
  solicitud_id bigint references public.solicitudes(id) on delete set null,
  origen text not null default 'solicitud', -- solicitud | comentario | asignacion | directo | meta | aviso | prueba
  actor uuid,                               -- quien provocó el aviso (si se sabe)
  dispositivos int not null default 0,
  entregados int not null default 0
);
create index if not exists push_historial_fecha on public.push_historial (enviado_en desc);
create index if not exists push_historial_user on public.push_historial (user_id, enviado_en desc);
create index if not exists push_historial_sol on public.push_historial (solicitud_id);

alter table public.push_historial enable row level security;
drop policy if exists push_historial_admin on public.push_historial;
create policy push_historial_admin on public.push_historial for select to authenticated using (public.mi_rol() = 'admin');
revoke all on public.push_historial from anon;
revoke insert, update, delete on public.push_historial from authenticated;
grant select on public.push_historial to authenticated;

-- Se conserva 6 meses
select cron.unschedule('vc_push_historial_limpieza') where exists (select 1 from cron.job where jobname = 'vc_push_historial_limpieza');
select cron.schedule('vc_push_historial_limpieza', '15 9 * * 0', $$delete from public.push_historial where enviado_en < now() - interval '180 days'$$);

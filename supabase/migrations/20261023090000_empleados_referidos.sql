-- Empleados de Más Pisto (usen o no la app) para "Referido por empleado". Los administra el admin en Usuarios.
create table if not exists public.empleados (
  id bigint generated always as identity primary key,
  nombre text not null,
  cargo text,
  perfil_id uuid references public.perfiles(id),
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);
alter table public.empleados enable row level security;
create policy empleados_sel on public.empleados for select using ((select mi_rol()) is not null);
create policy empleados_ins on public.empleados for insert with check ((select mi_rol()) = 'admin');
create policy empleados_upd on public.empleados for update using ((select mi_rol()) = 'admin') with check ((select mi_rol()) = 'admin');

alter table public.solicitudes add column if not exists referido_empleado_id bigint references public.empleados(id);

-- Lista inicial: usuarios activos de la app + empleados ya escritos a mano en referidos
insert into public.empleados (nombre, cargo, perfil_id)
select nombre, initcap(rol), id from public.perfiles where activo;
insert into public.empleados (nombre)
select distinct trim(referido_nombre) from public.solicitudes
 where origen_canal = 'referido_empleado' and referido_empleado is null and coalesce(trim(referido_nombre), '') <> ''
   and lower(trim(referido_nombre)) not in (select lower(nombre) from public.empleados);
update public.solicitudes s set referido_empleado_id = e.id from public.empleados e
 where s.origen_canal = 'referido_empleado' and s.referido_empleado_id is null
   and (e.perfil_id = s.referido_empleado or (s.referido_empleado is null and lower(e.nombre) = lower(trim(s.referido_nombre))));

-- Guarda cómo llegó el cliente; el empleado que refiere se elige de la lista de empleados
create or replace function public.guardar_origen_cliente(p_id bigint, p_canal text, p_referido_nombre text default null,
  p_referido_telefono text default null, p_referido_empleado_id bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare s solicitudes; r text := mi_rol(); e empleados;
begin
  select * into s from solicitudes where id = p_id;
  if s.id is null then raise exception 'Solicitud no encontrada'; end if;
  if r is null or not (r in ('admin', 'analista') or s.asesor_id = auth.uid()) then raise exception 'Sin permiso para cambiar el origen'; end if;
  if p_canal is not null and p_canal not in ('facebook','instagram','tiktok','whatsapp','referido_cliente','referido_empleado','oficina','volante','otro') then
    raise exception 'Canal no válido';
  end if;
  if p_canal = 'referido_cliente' and coalesce(trim(p_referido_nombre), '') = '' then raise exception 'Escriba el nombre del cliente que lo refirió'; end if;
  if p_canal = 'referido_empleado' then
    select * into e from empleados where id = p_referido_empleado_id;
    if e.id is null then raise exception 'Seleccione el empleado que lo refirió'; end if;
  end if;
  update solicitudes set origen_canal = p_canal, origen_asumido = false,
    referido_nombre = case when p_canal = 'referido_empleado' then e.nombre when p_canal in ('referido_cliente','otro') then nullif(trim(p_referido_nombre), '') end,
    referido_telefono = case when p_canal = 'referido_cliente' then nullif(trim(p_referido_telefono), '') end,
    referido_empleado = case when p_canal = 'referido_empleado' then e.perfil_id end,
    referido_empleado_id = case when p_canal = 'referido_empleado' then e.id end
  where id = p_id;
end $$;
revoke all on function public.guardar_origen_cliente(bigint, text, text, text, bigint) from public, anon;
grant execute on function public.guardar_origen_cliente(bigint, text, text, text, bigint) to authenticated;

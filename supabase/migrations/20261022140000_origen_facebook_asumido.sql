-- Clientes nuevos sin origen: se asume Facebook (la fuente principal) y se marcan como "asumido" para revisarlos a mano.
-- Al guardar el origen desde la app (aunque se confirme Facebook) deja de ser asumido.
alter table public.solicitudes add column if not exists origen_asumido boolean not null default false;

create or replace function public.guardar_origen(p_id bigint, p_canal text, p_referido_nombre text default null,
  p_referido_telefono text default null, p_referido_empleado uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare s solicitudes; r text := mi_rol();
begin
  select * into s from solicitudes where id = p_id;
  if s.id is null then raise exception 'Solicitud no encontrada'; end if;
  if r is null or not (r in ('admin', 'analista') or s.asesor_id = auth.uid()) then raise exception 'Sin permiso para cambiar el origen'; end if;
  if p_canal is not null and p_canal not in ('facebook','instagram','tiktok','whatsapp','referido_cliente','referido_empleado','oficina','volante','otro') then
    raise exception 'Canal no válido';
  end if;
  if p_canal = 'referido_cliente' and coalesce(trim(p_referido_nombre), '') = '' then raise exception 'Escriba el nombre del cliente que lo refirió'; end if;
  if p_canal = 'referido_empleado' and p_referido_empleado is null and coalesce(trim(p_referido_nombre), '') = '' then raise exception 'Indique el empleado que lo refirió'; end if;
  update solicitudes set origen_canal = p_canal, origen_asumido = false,
    referido_nombre = case when p_canal in ('referido_cliente','referido_empleado','otro') then nullif(trim(p_referido_nombre), '') end,
    referido_telefono = case when p_canal = 'referido_cliente' then nullif(trim(p_referido_telefono), '') end,
    referido_empleado = case when p_canal = 'referido_empleado' then p_referido_empleado end
  where id = p_id;
end $$;

update public.solicitudes set origen_canal = 'facebook', origen_asumido = true where tipo = 'nuevo' and origen_canal is null;

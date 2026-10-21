-- Cómo llegó el cliente nuevo (canal de captación), quién lo refirió y control del bono por referido.
alter table public.solicitudes
  add column if not exists origen_canal text,
  add column if not exists referido_nombre text,       -- cliente que refirió (o nombre libre)
  add column if not exists referido_telefono text,
  add column if not exists referido_empleado uuid references public.perfiles(id),
  add column if not exists bono_monto numeric,
  add column if not exists bono_pagado_en timestamptz,
  add column if not exists bono_pagado_por uuid references public.perfiles(id),
  add column if not exists bono_nota text;

-- Asesor dueño de la solicitud, analista o admin. Se puede corregir después de creada.
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
  update solicitudes set origen_canal = p_canal,
    referido_nombre = case when p_canal in ('referido_cliente','referido_empleado','otro') then nullif(trim(p_referido_nombre), '') end,
    referido_telefono = case when p_canal = 'referido_cliente' then nullif(trim(p_referido_telefono), '') end,
    referido_empleado = case when p_canal = 'referido_empleado' then p_referido_empleado end
  where id = p_id;
end $$;

-- Bono por referido: lo registra el admin o el analista (p_pagado = false lo deja pendiente otra vez)
create or replace function public.marcar_bono_referido(p_id bigint, p_pagado boolean, p_monto numeric default null, p_nota text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(mi_rol(), '') not in ('admin', 'analista') then raise exception 'Solo el administrador o el analista registran bonos'; end if;
  update solicitudes set
    bono_pagado_en = case when p_pagado then now() end,
    bono_pagado_por = case when p_pagado then auth.uid() end,
    bono_monto = case when p_pagado then p_monto end,
    bono_nota = nullif(trim(p_nota), '')
  where id = p_id and origen_canal in ('referido_cliente', 'referido_empleado');
  if not found then raise exception 'La solicitud no es de un cliente referido'; end if;
end $$;

revoke all on function public.guardar_origen(bigint, text, text, text, uuid), public.marcar_bono_referido(bigint, boolean, numeric, text) from public, anon;
grant execute on function public.guardar_origen(bigint, text, text, text, uuid), public.marcar_bono_referido(bigint, boolean, numeric, text) to authenticated;

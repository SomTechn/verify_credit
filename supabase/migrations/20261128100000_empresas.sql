-- Listado de empresas para la hoja de solicitud (autocompletar empresa, rubro y dirección).
create table if not exists public.empresas (
  id bigserial primary key,
  nombre text not null,
  rubro text,
  departamento text,
  ciudad text,
  sector text,
  colonia text,
  ref text,
  usos integer not null default 0,
  creado_por uuid default auth.uid(),
  creado_en timestamptz not null default now()
);
create unique index if not exists empresas_unico on public.empresas (lower(trim(nombre)));
alter table public.empresas enable row level security;
drop policy if exists empresas_sel on public.empresas;
create policy empresas_sel on public.empresas for select to authenticated using ((select public.mi_rol()) is not null);
revoke insert, update, delete on public.empresas from authenticated, anon;
grant select on public.empresas to authenticated;

-- Agrega o actualiza una empresa (asesor, analista, admin). Si existe suma un uso y completa lo que le faltaba.
create or replace function public.agregar_empresa(p_nombre text, p_rubro text default null, p_depto text default null,
  p_ciudad text default null, p_sector text default null, p_colonia text default null, p_ref text default null)
 returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; n text := trim(coalesce(p_nombre, ''));
begin
  if not tiene_rol('asesor', 'analista') then raise exception 'Sin permiso'; end if;
  if n = '' then raise exception 'Indique el nombre de la empresa'; end if;
  select id into v_id from empresas where lower(trim(nombre)) = lower(n);
  if v_id is null then
    insert into empresas (nombre, rubro, departamento, ciudad, sector, colonia, ref, usos)
    values (n, nullif(trim(coalesce(p_rubro, '')), ''), nullif(trim(coalesce(p_depto, '')), ''), nullif(trim(coalesce(p_ciudad, '')), ''),
      nullif(trim(coalesce(p_sector, '')), ''), nullif(trim(coalesce(p_colonia, '')), ''), nullif(trim(coalesce(p_ref, '')), ''), 1) returning id into v_id;
  else
    update empresas set usos = usos + 1,
      rubro = coalesce(rubro, nullif(trim(coalesce(p_rubro, '')), '')),
      departamento = case when colonia is null then coalesce(nullif(trim(coalesce(p_depto, '')), ''), departamento) else departamento end,
      ciudad = case when colonia is null then coalesce(nullif(trim(coalesce(p_ciudad, '')), ''), ciudad) else ciudad end,
      sector = case when colonia is null then coalesce(nullif(trim(coalesce(p_sector, '')), ''), sector) else sector end,
      ref = case when colonia is null then coalesce(nullif(trim(coalesce(p_ref, '')), ''), ref) else ref end,
      colonia = coalesce(colonia, nullif(trim(coalesce(p_colonia, '')), ''))
    where id = v_id;
  end if;
  return v_id;
end $$;

-- Administración (solo admin): nueva/editar (id nulo = nueva) y borrar
create or replace function public.guardar_empresa(p_id bigint, p_nombre text, p_rubro text, p_depto text, p_ciudad text, p_sector text, p_colonia text, p_ref text, p_borrar boolean default false)
 returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador puede editar el listado de empresas'; end if;
  if p_borrar then delete from empresas where id = p_id; return; end if;
  if trim(coalesce(p_nombre, '')) = '' then raise exception 'Indique el nombre de la empresa'; end if;
  if exists (select 1 from empresas where lower(trim(nombre)) = lower(trim(p_nombre)) and id is distinct from p_id) then raise exception 'Ya existe esa empresa'; end if;
  if p_id is null then
    insert into empresas (nombre, rubro, departamento, ciudad, sector, colonia, ref) values (trim(p_nombre), nullif(trim(coalesce(p_rubro, '')), ''), nullif(trim(coalesce(p_depto, '')), ''),
      nullif(trim(coalesce(p_ciudad, '')), ''), nullif(trim(coalesce(p_sector, '')), ''), nullif(trim(coalesce(p_colonia, '')), ''), nullif(trim(coalesce(p_ref, '')), ''));
  else
    update empresas set nombre = trim(p_nombre), rubro = nullif(trim(coalesce(p_rubro, '')), ''), departamento = nullif(trim(coalesce(p_depto, '')), ''), ciudad = nullif(trim(coalesce(p_ciudad, '')), ''),
      sector = nullif(trim(coalesce(p_sector, '')), ''), colonia = nullif(trim(coalesce(p_colonia, '')), ''), ref = nullif(trim(coalesce(p_ref, '')), '') where id = p_id;
  end if;
end $$;

-- Importar desde Excel: [{nombre, rubro, depto, ciudad, sector, colonia, ref}]; salta las existentes; devuelve cuántas insertó
create or replace function public.importar_empresas(p_filas jsonb)
 returns integer language plpgsql security definer set search_path to 'public' as $$
declare n integer := 0; f jsonb; c integer;
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador puede importar empresas'; end if;
  for f in select * from jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) loop
    if trim(coalesce(f->>'nombre', '')) = '' then continue; end if;
    insert into empresas (nombre, rubro, departamento, ciudad, sector, colonia, ref)
    values (trim(f->>'nombre'), nullif(trim(coalesce(f->>'rubro', '')), ''), nullif(trim(coalesce(f->>'depto', '')), ''), nullif(trim(coalesce(f->>'ciudad', '')), ''),
      nullif(trim(coalesce(f->>'sector', '')), ''), nullif(trim(coalesce(f->>'colonia', '')), ''), nullif(trim(coalesce(f->>'ref', '')), ''))
    on conflict do nothing;
    get diagnostics c = row_count; n := n + c;
  end loop;
  return n;
end $$;
grant execute on function public.agregar_empresa(text, text, text, text, text, text, text), public.guardar_empresa(bigint, text, text, text, text, text, text, text, boolean), public.importar_empresas(jsonb) to authenticated;

-- Semilla: las empresas que ya se escribieron en hojas
insert into public.empresas (nombre, rubro, ciudad, colonia, sector, ref, usos)
select min(trim(h->>'empresa')), max(nullif(trim(h->>'rubro'), '')), max(nullif(trim(h->'trab'->>'ciudad'), '')), max(nullif(trim(h->'trab'->>'colonia'), '')),
  max(nullif(trim(h->'trab'->>'sector'), '')), max(nullif(trim(h->'trab'->>'ref'), '')), count(*)
from (select datos_cliente->'hoja' h from public.solicitudes) x
where nullif(trim(h->>'empresa'), '') is not null
group by lower(trim(h->>'empresa'))
on conflict do nothing;

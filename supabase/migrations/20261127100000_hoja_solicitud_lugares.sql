-- Hoja de solicitud (la del Excel del asesor) dentro de VerifyCredit + banco de ciudades, sectores y colonias.
-- La hoja se guarda en solicitudes.datos_cliente->'hoja'; domicilio y trabajo también llenan dom_*/trab_* (sin tocar coordenadas).

create table if not exists public.lugares (
  id bigserial primary key,
  ciudad text not null,
  departamento text,
  sector text,
  colonia text not null,
  usos integer not null default 0,
  creado_por uuid default auth.uid(),
  creado_en timestamptz not null default now()
);
create unique index if not exists lugares_unico on public.lugares (lower(ciudad), lower(coalesce(sector, '')), lower(colonia));
alter table public.lugares enable row level security;
drop policy if exists lugares_sel on public.lugares;
create policy lugares_sel on public.lugares for select to authenticated using ((select public.mi_rol()) is not null);
revoke insert, update, delete on public.lugares from authenticated, anon;
grant select on public.lugares to authenticated;

create or replace function public.depto_de(p_ciudad text) returns text language sql immutable as $$
  select case lower(coalesce(p_ciudad, ''))
    when 'el progreso' then 'Yoro' when 'tela' then 'Atlántida' when 'la ceiba' then 'Atlántida'
    when 'tegucigalpa' then 'Francisco Morazán' when 'comayagua' then 'Comayagua'
    when 'santa cruz de yojoa' then 'Cortés'
    else 'Cortés' end
$$;

-- Agrega un lugar al banco (o suma un uso si ya existe). Asesor, analista o admin.
create or replace function public.agregar_lugar(p_ciudad text, p_sector text, p_colonia text)
 returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; c text := initcap(trim(coalesce(p_ciudad, ''))); se text := nullif(trim(coalesce(p_sector, '')), ''); co text := nullif(trim(coalesce(p_colonia, '')), '');
begin
  if not tiene_rol('asesor', 'analista') then raise exception 'Sin permiso'; end if;
  if c = '' or co is null then raise exception 'Indique la ciudad y la colonia'; end if;
  select id into v_id from lugares where lower(ciudad) = lower(c) and lower(coalesce(sector, '')) = lower(coalesce(se, '')) and lower(colonia) = lower(co);
  if v_id is null then
    insert into lugares (ciudad, departamento, sector, colonia, usos) values (c, depto_de(c), se, co, 1) returning id into v_id;
  else
    update lugares set usos = usos + 1 where id = v_id;
  end if;
  return v_id;
end $$;

-- Administración del banco (solo admin)
create or replace function public.editar_lugar(p_id bigint, p_ciudad text, p_sector text, p_colonia text, p_borrar boolean default false)
 returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador puede editar el banco de lugares'; end if;
  if p_borrar then delete from lugares where id = p_id; return; end if;
  if trim(coalesce(p_ciudad, '')) = '' or trim(coalesce(p_colonia, '')) = '' then raise exception 'Indique la ciudad y la colonia'; end if;
  update lugares set ciudad = trim(p_ciudad), departamento = depto_de(trim(p_ciudad)), sector = nullif(trim(coalesce(p_sector, '')), ''), colonia = trim(p_colonia) where id = p_id;
end $$;

-- Guarda la hoja de solicitud. Asesor/analista/admin, solicitud abierta (admin siempre).
-- La cantidad que pide el cliente va en la hoja (hoja.monto); monto_solicitado sigue siendo lo que toma al completar.
create or replace function public.guardar_hoja(p_id bigint, p_hoja jsonb, p_plazo integer default null,
  p_telefono text default null, p_nombre text default null)
 returns void language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes; d jsonb; t jsonb;
begin
  if not tiene_rol('asesor', 'analista') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado in ('desembolsada', 'denegada', 'rechazada_verificacion', 'desistida') and coalesce(mi_rol(), '') <> 'admin' then
    raise exception 'La solicitud ya está cerrada'; end if;
  if p_plazo is not null and (p_plazo < 1 or p_plazo > 60) then raise exception 'Plazo no válido'; end if;
  d := coalesce(p_hoja->'dom', '{}'::jsonb); t := coalesce(p_hoja->'trab', '{}'::jsonb);
  update solicitudes set
    datos_cliente = coalesce(datos_cliente, '{}'::jsonb)
      || jsonb_build_object('hoja', coalesce(datos_cliente->'hoja', '{}'::jsonb) || coalesce(p_hoja, '{}'::jsonb))
      || case when nullif(p_hoja->>'nac', '') is not null then jsonb_build_object('fecha_nacimiento', p_hoja->>'nac') else '{}'::jsonb end,
    plazo_meses = coalesce(p_plazo, plazo_meses),
    telefono = coalesce(nullif(trim(coalesce(p_telefono, '')), ''), telefono),
    nombre_cliente = coalesce(nullif(trim(coalesce(p_nombre, '')), ''), nombre_cliente),
    dom_sector = case when p_hoja ? 'dom' then coalesce(nullif(trim(coalesce(d->>'colonia', '')), ''), nullif(trim(coalesce(d->>'sector', '')), ''), dom_sector) else dom_sector end,
    dom_ciudad = case when p_hoja ? 'dom' then coalesce(nullif(trim(coalesce(d->>'ciudad', '')), ''), dom_ciudad) else dom_ciudad end,
    dom_ref = case when p_hoja ? 'dom' then coalesce(nullif(trim(coalesce(d->>'ref', '')), ''), dom_ref) else dom_ref end,
    trab_sector = case when p_hoja ? 'trab' then coalesce(nullif(trim(coalesce(t->>'colonia', '')), ''), nullif(trim(coalesce(t->>'sector', '')), ''), trab_sector) else trab_sector end,
    trab_ciudad = case when p_hoja ? 'trab' then coalesce(nullif(trim(coalesce(t->>'ciudad', '')), ''), trab_ciudad) else trab_ciudad end,
    trab_ref = case when p_hoja ? 'trab' then coalesce(nullif(trim(coalesce(t->>'ref', '')), ''), trab_ref) else trab_ref end
  where id = p_id;
end $$;

grant execute on function public.agregar_lugar(text, text, text), public.editar_lugar(bigint, text, text, text, boolean),
  public.guardar_hoja(bigint, jsonb, integer, text, text) to authenticated;

-- Banco inicial: las colonias que ya se registraron en domicilios y trabajos
insert into public.lugares (ciudad, departamento, sector, colonia, usos)
select ciudad, depto_de(ciudad), null, colonia, count(*)
from (
  select initcap(trim(dom_ciudad)) ciudad, trim(dom_sector) colonia from public.solicitudes where dom_sector is not null and dom_ciudad is not null
  union all
  select initcap(trim(trab_ciudad)), trim(trab_sector) from public.solicitudes where trab_sector is not null and trab_ciudad is not null
) x
where colonia <> '' and colonia not ilike 'sector:%' and lower(ciudad) <> 'otra'
group by ciudad, colonia
on conflict do nothing;

-- Banco de lugares: departamento elegible, alta/edición por el administrador e importación desde Excel.
drop function if exists public.agregar_lugar(text, text, text);
create or replace function public.agregar_lugar(p_ciudad text, p_sector text, p_colonia text, p_depto text default null)
 returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; c text := trim(coalesce(p_ciudad, '')); se text := nullif(trim(coalesce(p_sector, '')), ''); co text := nullif(trim(coalesce(p_colonia, '')), '');
  dp text := coalesce(nullif(trim(coalesce(p_depto, '')), ''), depto_de(p_ciudad));
begin
  if not tiene_rol('asesor', 'analista') then raise exception 'Sin permiso'; end if;
  if c = '' or co is null then raise exception 'Indique la ciudad y la colonia'; end if;
  select id into v_id from lugares where lower(ciudad) = lower(c) and lower(coalesce(sector, '')) = lower(coalesce(se, '')) and lower(colonia) = lower(co);
  if v_id is null then
    insert into lugares (ciudad, departamento, sector, colonia, usos) values (c, dp, se, co, 1) returning id into v_id;
  else
    update lugares set usos = usos + 1 where id = v_id;
  end if;
  return v_id;
end $$;

-- Alta o edición (p_id null = nueva) por el administrador
create or replace function public.guardar_lugar(p_id bigint, p_depto text, p_ciudad text, p_sector text, p_colonia text)
 returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint := p_id; c text := trim(coalesce(p_ciudad, '')); co text := trim(coalesce(p_colonia, ''));
  se text := nullif(trim(coalesce(p_sector, '')), ''); dp text := coalesce(nullif(trim(coalesce(p_depto, '')), ''), depto_de(p_ciudad));
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador puede editar el banco de lugares'; end if;
  if c = '' or co = '' then raise exception 'Indique la ciudad y la colonia'; end if;
  if exists (select 1 from lugares where lower(ciudad) = lower(c) and lower(coalesce(sector, '')) = lower(coalesce(se, '')) and lower(colonia) = lower(co) and id is distinct from p_id) then
    raise exception 'Ya existe esa colonia en el banco'; end if;
  if p_id is null then
    insert into lugares (ciudad, departamento, sector, colonia) values (c, dp, se, co) returning id into v_id;
  else
    update lugares set ciudad = c, departamento = dp, sector = se, colonia = co where id = p_id;
  end if;
  return v_id;
end $$;

-- Importación: [{depto, ciudad, sector, colonia}, ...]; las repetidas se ignoran. Devuelve cuántas se agregaron.
create or replace function public.importar_lugares(p_filas jsonb)
 returns integer language plpgsql security definer set search_path to 'public' as $$
declare n integer;
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador puede importar lugares'; end if;
  with f as (
    select distinct on (lower(trim(x->>'ciudad')), lower(coalesce(nullif(trim(x->>'sector'), ''), '')), lower(trim(x->>'colonia')))
      trim(x->>'ciudad') ciudad, coalesce(nullif(trim(x->>'depto'), ''), depto_de(x->>'ciudad')) depto, nullif(trim(x->>'sector'), '') sector, trim(x->>'colonia') colonia
    from jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) x
    where coalesce(trim(x->>'ciudad'), '') <> '' and coalesce(trim(x->>'colonia'), '') <> ''
  ), ins as (
    insert into lugares (ciudad, departamento, sector, colonia) select ciudad, depto, sector, colonia from f
    on conflict do nothing returning 1
  ) select count(*) into n from ins;
  return n;
end $$;

grant execute on function public.agregar_lugar(text, text, text, text), public.guardar_lugar(bigint, text, text, text, text), public.importar_lugares(jsonb) to authenticated;

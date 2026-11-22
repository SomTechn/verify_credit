-- Récord, "Esta semana" y "Mi ritmo" miden una sola cosa clara según el rol (pedido de Somar, 21-nov):
--   asesor: solicitudes enviadas a análisis · analista/admin (y gerente): dictámenes (aprobadas o denegadas) · verificador: visitas (domicilio/trabajo).
create or replace function public.mi_progreso()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  yo uuid := auth.uid(); r text := mi_rol();
  v_hoy date := (now() at time zone 'America/Tegucigalpa')::date;
  v_paso text := case mi_rol() when 'asesor' then 'borrador' when 'verificador' then 'por_verificar' else 'en_analisis' end;
  v_m text := case mi_rol() when 'asesor' then 'asesor' when 'verificador' then 'verificador' else 'analista' end;
  v_lun date; d date; i int; racha int := 0; mejor int := 0; corr int := 0; prev date; hoy_limpia boolean;
  rec jsonb; x record;
begin
  if yo is null or r is null then return null; end if;
  v_lun := v_hoy - (extract(isodow from v_hoy)::int - 1);

  hoy_limpia := exists (select 1 from bandeja_limpia where usuario_id = yo and dia = v_hoy);
  d := v_hoy; if not hoy_limpia then d := v_hoy - 1; end if;
  for i in 1..400 loop
    while not es_dia_habil(d) loop d := d - 1; end loop;
    exit when not exists (select 1 from bandeja_limpia where usuario_id = yo and dia = d);
    racha := racha + 1; d := d - 1;
  end loop;
  for x in select dia from bandeja_limpia where usuario_id = yo order by dia loop
    if prev is not null and not exists (select 1 from generate_series(prev + 1, x.dia - 1, interval '1 day') g where es_dia_habil(g::date))
      then corr := corr + 1; else corr := 1; end if;
    mejor := greatest(mejor, corr); prev := x.dia;
  end loop;

  with
  -- Lo que cuenta para el récord y la semana
  m as (
    select (e.creado_en at time zone 'America/Tegucigalpa')::date dia
    from eventos e join solicitudes s on s.id = e.solicitud_id
    where e.usuario_id = yo and not coalesce(s.importado, false) and e.creado_en >= now() - interval '180 days'
      and ((v_m = 'asesor' and e.de_estado = 'borrador' and e.a_estado = 'en_analisis')
        or (v_m = 'analista' and e.de_estado = 'en_analisis' and e.a_estado in ('aprobada','denegada')))
    union all
    select (v.creado_en at time zone 'America/Tegucigalpa')::date
    from visitas v where v_m = 'verificador' and v.verificador_id = yo and v.tipo in ('domicilio','trabajo') and v.creado_en >= now() - interval '180 days'
  ),
  md as (select dia, count(*) n from m group by dia),
  ms as (select date_trunc('week', dia)::date lun, count(*) n from m group by 1),
  -- Tiempos del paso principal (para el promedio de la semana y el mejor tiempo)
  ev as (
    select (e.creado_en at time zone 'America/Tegucigalpa')::date dia, e.duracion_habil_seg::numeric seg
    from eventos e join solicitudes s on s.id = e.solicitud_id
    where e.usuario_id = yo and e.de_estado = v_paso and e.a_estado is not null and e.a_estado <> e.de_estado and e.a_estado <> 'desistida'
      and not coalesce(s.importado, false) and e.creado_en >= now() - interval '180 days'
  ),
  tope as (select coalesce(percentile_cont(.9) within group (order by seg), 1e12) p90 from ev where dia < v_hoy),
  td as (select dia, avg(least(seg, (select p90 from tope))) prom, count(*) np from ev group by dia)
  select jsonb_build_object(
    'paso', v_paso, 'medida', v_m,
    'unidad', case v_m when 'asesor' then 'enviadas a análisis' when 'verificador' then 'visitas' else 'dictámenes' end,
    'hoy_n', coalesce((select n from md where dia = v_hoy), 0),
    'prom_diario30', (select round(sum(n)::numeric / nullif(count(*), 0), 1) from md where dia >= v_hoy - 30 and dia < v_hoy),
    'mejor_dia', (select jsonb_build_object('n', n, 'dia', dia) from md where dia < v_hoy order by n desc, dia desc limit 1),
    'mejor_tiempo', (select jsonb_build_object('seg', round(prom), 'dia', dia) from td where dia < v_hoy and np >= 3 order by prom asc limit 1),
    'mejor_semana', (select jsonb_build_object('n', n, 'lun', lun) from ms where lun < v_lun order by n desc, lun desc limit 1),
    'semana', jsonb_build_object(
      'actual', jsonb_build_object('desde', v_lun,
        'n', (select count(*) from m where dia >= v_lun),
        'prom', (select round(avg(least(seg, (select p90 from tope)))) from ev where dia >= v_lun),
        'dias_limpia', (select count(*) from bandeja_limpia where usuario_id = yo and dia >= v_lun),
        'colocado', (select coalesce(sum(capital_colocado(s)), 0) from solicitudes s where s.asesor_id = yo and s.estado = 'desembolsada' and dia_colocacion(s) >= v_lun),
        'mejor_dia', (select jsonb_build_object('n', n, 'dia', dia) from md where dia >= v_lun order by n desc limit 1)),
      'anterior', jsonb_build_object('desde', v_lun - 7,
        'n', (select count(*) from m where dia >= v_lun - 7 and dia < v_lun),
        'prom', (select round(avg(least(seg, (select p90 from tope)))) from ev where dia >= v_lun - 7 and dia < v_lun),
        'dias_limpia', (select count(*) from bandeja_limpia where usuario_id = yo and dia >= v_lun - 7 and dia < v_lun),
        'colocado', (select coalesce(sum(capital_colocado(s)), 0) from solicitudes s where s.asesor_id = yo and s.estado = 'desembolsada' and dia_colocacion(s) >= v_lun - 7 and dia_colocacion(s) < v_lun),
        'mejor_dia', (select jsonb_build_object('n', n, 'dia', dia) from md where dia >= v_lun - 7 and dia < v_lun order by n desc limit 1),
        'dias_trab', (select count(*) from md where dia >= v_lun - 7 and dia < v_lun)))
  ) into rec;

  return rec || jsonb_build_object('racha', racha, 'mejor_racha', greatest(mejor, racha), 'hoy_limpia', hoy_limpia);
end $$;

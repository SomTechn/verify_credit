-- Motivación en "Mi trabajo": rachas de bandeja limpia, récords personales y resumen semanal.

-- Día hábil (lunes a sábado, sin feriados)
create or replace function public.es_dia_habil(d date)
returns boolean language sql stable set search_path = public as $$
  select extract(isodow from d) < 7 and not exists (select 1 from feriados f where f.fecha = d);
$$;

-- Días en que el usuario dejó la bandeja limpia (antes del cierre: 4:30 p. m.; sábado 12:00 m.)
create table if not exists public.bandeja_limpia (
  usuario_id uuid not null references public.perfiles(id) on delete cascade,
  dia date not null,
  registrado_en timestamptz not null default now(),
  completadas int not null default 0,
  primary key (usuario_id, dia)
);
alter table public.bandeja_limpia enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='bandeja_limpia' and policyname='bandeja_limpia_sel') then
    create policy bandeja_limpia_sel on public.bandeja_limpia for select using (usuario_id = auth.uid());
  end if;
end $$;

-- Pasos que cuentan como trabajo completado
create or replace function public._pasos_completados()
returns text[] language sql immutable as $$ select array['borrador','en_analisis','aprobada','por_verificar','desembolso_pendiente'] $$;

create or replace function public.registrar_bandeja_limpia()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_now timestamp := now() at time zone 'America/Tegucigalpa'; v_dia date := v_now::date; n int;
begin
  if auth.uid() is null or mi_rol() is null then return null; end if;
  if not es_dia_habil(v_dia) then return jsonb_build_object('ok', false, 'motivo', 'no_habil'); end if;
  if v_now::time > (case when extract(isodow from v_dia) = 6 then time '12:00' else time '16:30' end) then
    return jsonb_build_object('ok', false, 'motivo', 'fuera_de_hora'); end if;
  select count(*) into n from eventos e
   where e.usuario_id = auth.uid() and e.de_estado = any(_pasos_completados())
     and e.a_estado is not null and e.a_estado <> e.de_estado and e.a_estado <> 'desistida'
     and (e.creado_en at time zone 'America/Tegucigalpa')::date = v_dia;
  if n = 0 then return jsonb_build_object('ok', false, 'motivo', 'sin_actividad'); end if;
  insert into bandeja_limpia (usuario_id, dia, completadas) values (auth.uid(), v_dia, n)
  on conflict (usuario_id, dia) do update set completadas = excluded.completadas;
  return jsonb_build_object('ok', true, 'completadas', n);
end $$;

create or replace function public.mi_progreso()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  yo uuid := auth.uid(); r text := mi_rol();
  v_hoy date := (now() at time zone 'America/Tegucigalpa')::date;
  v_paso text := case mi_rol() when 'asesor' then 'borrador' when 'verificador' then 'por_verificar' else 'en_analisis' end;
  v_lun date; d date; i int; racha int := 0; mejor int := 0; corr int := 0; prev date; hoy_limpia boolean;
  rec jsonb; sem jsonb; x record;
begin
  if yo is null or r is null then return null; end if;
  v_lun := v_hoy - (extract(isodow from v_hoy)::int - 1);

  -- Racha actual: días hábiles seguidos con bandeja limpia (hoy cuenta si ya se registró; si no, sigue viva desde ayer)
  hoy_limpia := exists (select 1 from bandeja_limpia where usuario_id = yo and dia = v_hoy);
  d := v_hoy; if not hoy_limpia then d := v_hoy - 1; end if;
  for i in 1..400 loop
    while not es_dia_habil(d) loop d := d - 1; end loop;
    exit when not exists (select 1 from bandeja_limpia where usuario_id = yo and dia = d);
    racha := racha + 1; d := d - 1;
  end loop;
  -- Mejor racha histórica
  for x in select dia from bandeja_limpia where usuario_id = yo order by dia loop
    if prev is not null and not exists (select 1 from generate_series(prev + 1, x.dia - 1, interval '1 day') g where es_dia_habil(g::date))
      then corr := corr + 1; else corr := 1; end if;
    mejor := greatest(mejor, corr); prev := x.dia;
  end loop;

  with ev as (
    select (e.creado_en at time zone 'America/Tegucigalpa')::date dia, e.de_estado, e.duracion_habil_seg::numeric seg
    from eventos e join solicitudes s on s.id = e.solicitud_id
    where e.usuario_id = yo and e.de_estado = any(_pasos_completados())
      and e.a_estado is not null and e.a_estado <> e.de_estado and e.a_estado <> 'desistida'
      and not coalesce(s.importado, false) and e.creado_en >= now() - interval '180 days'
  ),
  tope as (select coalesce(percentile_cont(.9) within group (order by seg), 1e12) p90 from ev where de_estado = v_paso and dia < v_hoy),
  dia_ as (
    select dia, count(*) n, avg(least(seg, (select p90 from tope))) filter (where de_estado = v_paso) prom, count(*) filter (where de_estado = v_paso) np
    from ev group by dia
  ),
  sem_ as (select date_trunc('week', dia)::date lun, count(*) n from ev group by 1)
  select jsonb_build_object(
    'paso', v_paso,
    'hoy_n', coalesce((select n from dia_ where dia = v_hoy), 0),
    'mejor_dia', (select jsonb_build_object('n', n, 'dia', dia) from dia_ where dia < v_hoy order by n desc, dia desc limit 1),
    'mejor_tiempo', (select jsonb_build_object('seg', round(prom), 'dia', dia) from dia_ where dia < v_hoy and np >= 3 order by prom asc limit 1),
    'mejor_semana', (select jsonb_build_object('n', n, 'lun', lun) from sem_ where lun < v_lun order by n desc, lun desc limit 1),
    'semana', jsonb_build_object(
      'actual', jsonb_build_object('desde', v_lun,
        'n', (select count(*) from ev where dia >= v_lun),
        'prom', (select round(avg(least(seg, (select p90 from tope)))) from ev where dia >= v_lun and de_estado = v_paso),
        'dias_limpia', (select count(*) from bandeja_limpia where usuario_id = yo and dia >= v_lun),
        'colocado', (select coalesce(sum(capital_colocado(s)), 0) from solicitudes s where s.asesor_id = yo and s.estado = 'desembolsada' and dia_colocacion(s) >= v_lun),
        'mejor_dia', (select jsonb_build_object('n', n, 'dia', dia) from dia_ where dia >= v_lun order by n desc limit 1)),
      'anterior', jsonb_build_object('desde', v_lun - 7,
        'n', (select count(*) from ev where dia >= v_lun - 7 and dia < v_lun),
        'prom', (select round(avg(least(seg, (select p90 from tope)))) from ev where dia >= v_lun - 7 and dia < v_lun and de_estado = v_paso),
        'dias_limpia', (select count(*) from bandeja_limpia where usuario_id = yo and dia >= v_lun - 7 and dia < v_lun),
        'colocado', (select coalesce(sum(capital_colocado(s)), 0) from solicitudes s where s.asesor_id = yo and s.estado = 'desembolsada' and dia_colocacion(s) >= v_lun - 7 and dia_colocacion(s) < v_lun),
        'mejor_dia', (select jsonb_build_object('n', n, 'dia', dia) from dia_ where dia >= v_lun - 7 and dia < v_lun order by n desc limit 1),
        'dias_trab', (select count(distinct dia) from ev where dia >= v_lun - 7 and dia < v_lun)))
  ) into rec;

  return rec || jsonb_build_object('racha', racha, 'mejor_racha', greatest(mejor, racha), 'hoy_limpia', hoy_limpia);
end $$;

revoke all on function public.registrar_bandeja_limpia() from public, anon;
revoke all on function public.mi_progreso() from public, anon;
grant execute on function public.registrar_bandeja_limpia() to authenticated;
grant execute on function public.mi_progreso() to authenticated;

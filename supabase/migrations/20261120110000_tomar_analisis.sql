-- Análisis en dos tramos:
--   cola_analisis : desde que el asesor envía hasta que un analista toca "Tomar análisis"
--   en_analisis   : desde que se toma hasta el dictamen
-- El evento 'analisis_tomado' (de_estado 'cola_analisis' → a_estado 'en_analisis') guarda la espera
-- y, como tiene a_estado, el dictamen mide su duración desde ese momento.

alter table public.solicitudes
  add column if not exists analisis_tomado_en timestamptz,
  add column if not exists analisis_tomado_por uuid references public.perfiles(id);

-- Al (re)entrar a análisis queda sin tomar
create or replace function public.tg_analisis_cola()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.estado = 'en_analisis' and old.estado is distinct from 'en_analisis' then
    new.analisis_tomado_en := null;
    new.analisis_tomado_por := null;
  end if;
  return new;
end $$;

drop trigger if exists analisis_cola on public.solicitudes;
create trigger analisis_cola before update of estado on public.solicitudes
  for each row execute function public.tg_analisis_cola();

-- Tomar el análisis (o quitárselo a otro analista)
create or replace function public.tomar_analisis(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare s solicitudes; v_prev text;
begin
  if not tiene_rol('analista') then raise exception 'Solo el analista puede tomar el análisis'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'en_analisis' then raise exception 'La solicitud ya no está en análisis'; end if;
  if s.analisis_tomado_en is not null then
    if s.analisis_tomado_por = auth.uid() then return; end if;
    select nombre into v_prev from perfiles where id = s.analisis_tomado_por;
    update solicitudes set analisis_tomado_por = auth.uid() where id = p_id;
    perform _evento(p_id, 'analisis_reasignado', null, null, 'Lo tenía ' || coalesce(v_prev, 'otro analista'));
    return;
  end if;
  update solicitudes set analisis_tomado_en = now(), analisis_tomado_por = auth.uid(), estado_desde = now() where id = p_id;
  perform _evento(p_id, 'analisis_tomado', 'cola_analisis', 'en_analisis', null);
end $$;

revoke all on function public.tomar_analisis(bigint) from public, anon;
grant execute on function public.tomar_analisis(bigint) to authenticated;

-- dictaminar exige que el análisis esté tomado
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.dictaminar(bigint,text,text,numeric,numeric,numeric,jsonb)'::regprocedure);
  if position('Tomar análisis' in d) = 0 then
    d := replace(d,
      $x$if s.estado <> 'en_analisis' then raise exception 'La solicitud no está en análisis'; end if;$x$,
      $x$if s.estado <> 'en_analisis' then raise exception 'La solicitud no está en análisis'; end if;
  if s.analisis_tomado_en is null then raise exception 'Primero toque "Tomar análisis"'; end if;$x$);
    if position('Tomar análisis' in d) = 0 then raise exception 'No se pudo modificar dictaminar'; end if;
    execute d;
  end if;

  -- Reportes: la espera de análisis es un paso aparte
  d := pg_get_functiondef('public.reporte_tiempos(date,date)'::regprocedure);
  if position('cola_analisis' in d) = 0 then
    d := replace(d, $x$array['borrador','en_analisis',$x$, $x$array['borrador','cola_analisis','en_analisis',$x$);
    if position('cola_analisis' in d) = 0 then raise exception 'No se pudo modificar reporte_tiempos'; end if;
    execute d;
  end if;

  d := pg_get_functiondef('public.estadisticas_tiempos(date,date)'::regprocedure);
  if position('cola_analisis' in d) = 0 then
    d := replace(d, $x$'borrador','en_analisis',$x$, $x$'borrador','cola_analisis','en_analisis',$x$);
    d := replace(d, $x$('desistida','regresada_revisadas')$x$, $x$('desistida','regresada_revisadas','analisis_tomado')$x$);
    if position('cola_analisis' in d) = 0 then raise exception 'No se pudo modificar estadisticas_tiempos'; end if;
    execute d;
  end if;
end $mig$;

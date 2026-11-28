-- Cambio de modalidad y reestructuración: no hay desembolso físico (solo cambio en el sistema).
-- 1) No cuentan en las estadísticas de crédito (solo en Cámbiate a nivelado).
-- 2) Cuando el analista aprueba, la solicitud se finaliza (queda cerrada, sin completar, verificar ni desembolsar).
create or replace function sol_credito() returns setof solicitudes
language sql stable security definer set search_path to 'public' as $$
  select * from solicitudes where tipo not in ('cambio_modalidad','reestructuracion')
$$;

do $$
declare f text; d text;
begin
  foreach f in array array['estadisticas','estadisticas_tiempos','reporte_tiempos','mi_progreso'] loop
    select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = f;
    d := regexp_replace(d, '(from|join)\s+solicitudes\s+(?!where\M|group\M|order\M|on\M|limit\M|join\M|left\M|union\M)([a-z_]\w*)', '\1 sol_credito() \2', 'gi');
    d := regexp_replace(d, '(from|join)\s+solicitudes\M(?!\.)', '\1 sol_credito() solicitudes', 'gi');
    if d ~* '(from|join)\s+solicitudes\M' then raise exception 'Quedó una consulta sin filtrar en %', f; end if;
    execute d;
  end loop;
end $$;

create or replace function dictaminar(p_id bigint, p_dictamen text, p_nota text default null, p_monto numeric default null, p_saldo_capital numeric default null, p_saldo_intereses numeric default null, p_analisis jsonb default null) returns void
language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes; a jsonb; v_creador uuid; v_dest uuid; v_neg boolean;
begin
  if not tiene_rol('analista') then raise exception 'Solo el analista puede dictaminar'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'en_analisis' then raise exception 'La solicitud no está en análisis'; end if;
  if s.analisis_tomado_en is null then raise exception 'Primero toque "Tomar análisis"'; end if;
  v_neg := s.tipo in ('cambio_modalidad','reestructuracion');

  -- El dictamen (o la devolución) regresa la solicitud al asesor que la creó
  select e.usuario_id into v_creador from eventos e join perfiles p on p.id = e.usuario_id
   where e.solicitud_id = p_id and e.accion = 'creada' and p.activo and p.rol in ('asesor','admin')
   order by e.creado_en limit 1;
  v_dest := case when v_neg then s.asesor_id else coalesce(v_creador, s.asesor_id) end;

  if p_dictamen = 'devolver' then
    if length(trim(coalesce(p_nota,''))) = 0 then raise exception 'Indique qué debe corregir el asesor'; end if;
    update solicitudes set estado = 'borrador', asesor_id = v_dest where id = p_id;
    perform _evento(p_id, 'devuelta_asesor', 'en_analisis', 'borrador', p_nota);
    return;
  end if;
  if p_dictamen not in ('aprobada','denegada') then raise exception 'Dictamen inválido'; end if;
  if p_dictamen = 'aprobada' and coalesce(p_monto,0) <= 0 then raise exception 'Indique el monto aprobado'; end if;
  if p_dictamen = 'denegada' and length(trim(coalesce(p_nota,''))) = 0 then raise exception 'Indique el motivo de la denegación'; end if;

  if v_neg then
    if p_dictamen = 'aprobada' then
      if s.plazo_meses is null or s.saldo_capital is null or s.saldo_intereses is null then
        raise exception 'Confirme plazo, capital e intereses antes de aprobar'; end if;
      if s.contrato_firmado_path is null then raise exception 'Falta el contrato firmado'; end if;
    end if;
    update solicitudes set
      estado = case when p_dictamen = 'aprobada' then 'desembolsada' else 'denegada' end,
      dictamen_nota = nullif(trim(coalesce(p_nota,'')),''),
      monto_aprobado = case when p_dictamen = 'aprobada' then p_monto end,
      monto_solicitado = case when p_dictamen = 'aprobada' then p_monto else monto_solicitado end,
      analisis_resultado = p_analisis,
      negociacion_confirmada_en = case when p_dictamen = 'aprobada' then now() end,
      negociacion_confirmada_por = case when p_dictamen = 'aprobada' then auth.uid() end,
      desembolsado_en = case when p_dictamen = 'aprobada' then now() else desembolsado_en end,
      desembolsado_por = case when p_dictamen = 'aprobada' then auth.uid() else desembolsado_por end,
      fecha_colocacion = case when p_dictamen = 'aprobada' then (now() at time zone 'America/Tegucigalpa')::date else fecha_colocacion end,
      analista_id = auth.uid(), dictamen_en = now()
    where id = p_id;
    perform _evento(p_id, 'dictamen_' || p_dictamen, 'en_analisis', case when p_dictamen = 'aprobada' then 'desembolsada' else 'denegada' end,
      concat_ws(' · ', nullif(trim(coalesce(p_nota,'')),''),
        case when p_dictamen = 'aprobada' then 'Negociación confirmada: cambio aplicado en el sistema, finalizada sin desembolso' end));
    return;
  end if;

  a := calcular_analisis(p_id);
  update solicitudes set estado = p_dictamen, dictamen_nota = nullif(trim(coalesce(p_nota,'')),''),
    monto_aprobado = case when p_dictamen='aprobada' then p_monto end,
    saldo_capital = coalesce(p_saldo_capital, saldo_capital), saldo_intereses = coalesce(p_saldo_intereses, saldo_intereses),
    tasa_preferencial = coalesce((p_analisis->>'tasa_preferencial')::boolean, (p_analisis->>'pref')::boolean, (a->>'tasa_preferencial')::boolean),
    analisis_resultado = p_analisis,
    asesor_id = v_dest,
    analista_id = auth.uid(), dictamen_en = now()
  where id = p_id;
  perform _evento(p_id, 'dictamen_' || p_dictamen, 'en_analisis', p_dictamen,
    concat_ws(' · ', nullif(trim(coalesce(p_nota,'')),''), 'Regresa a ' || (select nombre from perfiles where id = v_dest)));
end $$;

-- Sin desembolso físico: el capital colocado de estos tipos es 0 en cualquier cálculo
create or replace function capital_colocado(s solicitudes) returns numeric
language sql immutable set search_path to 'public' as $$
  select case
    when s.tipo in ('cambio_modalidad','reestructuracion') then 0
    when s.capital_colocado_hist is not null then s.capital_colocado_hist
    when s.tipo <> 'nuevo' then greatest(0, coalesce(s.monto_solicitado, s.monto_aprobado, 0) - coalesce(s.saldo_capital, 0))
    else coalesce(s.monto_solicitado, s.monto_aprobado, 0) end
$$;

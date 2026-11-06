-- Fecha de colocación: el día en que el desembolso cuenta para la meta y las estadísticas.
-- Por defecto es el día real del desembolso; al marcar desembolsada (transferencia o efectivo) se puede
-- elegir otro día (ej. el desembolso tocaba ayer y se hizo hoy). desembolsado_en sigue siendo la hora real
-- (los tiempos y el ciclo no cambian).
-- Además: las solicitudes en espera no cuentan como "creadas" en las estadísticas.

alter table public.solicitudes add column if not exists fecha_colocacion date;

update public.solicitudes
   set fecha_colocacion = (coalesce(desembolsado_en, cerrado_en) at time zone 'America/Tegucigalpa')::date
 where estado = 'desembolsada' and fecha_colocacion is null and coalesce(desembolsado_en, cerrado_en) is not null;

create index if not exists solicitudes_fecha_colocacion_idx on public.solicitudes (fecha_colocacion) where estado = 'desembolsada';

-- Trigger de estado: toda desembolsada tiene fecha de colocación; si deja de estar desembolsada se borra.
create or replace function public.tg_solicitud_estado()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  if new.estado is distinct from old.estado then
    new.estado_desde := now();
    if old.en_espera and new.en_espera then
      new.en_espera := false;
      new.espera_total_seg := new.espera_total_seg + round(extract(epoch from now() - old.espera_desde))::int;
      new.espera_total_habil_seg := new.espera_total_habil_seg + coalesce(segundos_habiles(old.espera_desde, now()), 0);
      insert into eventos (solicitud_id, usuario_id, accion, nota)
        values (new.id, auth.uid(), 'reanudada', 'Automático al pasar a ' || new.estado || ' · En espera por: ' || coalesce(old.espera_motivo,''));
      new.espera_motivo := null; new.espera_desde := null; new.espera_por := null;
    end if;
    -- Toda solicitud desembolsada debe tener fecha de desembolso (incluye cambios manuales del admin)
    if new.estado = 'desembolsada' and new.desembolsado_en is null then
      new.desembolsado_en := now();
    end if;
    if new.estado in ('desembolsada','denegada','rechazada_verificacion','desistida') then
      new.cerrado_en := now();
      new.duracion_total_seg := round(extract(epoch from now() - new.creado_en))::int;
      new.duracion_total_habil_seg := segundos_habiles(new.creado_en, now());
    else
      new.cerrado_en := null; new.duracion_total_seg := null; new.duracion_total_habil_seg := null;
    end if;
  end if;
  if new.estado = 'desembolsada' then
    if new.fecha_colocacion is null then
      new.fecha_colocacion := (coalesce(new.desembolsado_en, now()) at time zone 'America/Tegucigalpa')::date;
    elsif tg_op = 'UPDATE' and old.estado = 'desembolsada' and new.desembolsado_en is distinct from old.desembolsado_en
          and new.fecha_colocacion is not distinct from old.fecha_colocacion and new.desembolsado_en is not null then
      -- El admin corrigió la fecha de desembolso: la colocación la sigue
      new.fecha_colocacion := (new.desembolsado_en at time zone 'America/Tegucigalpa')::date;
    end if;
  else
    new.fecha_colocacion := null;
  end if;
  return new;
end $function$;

-- Validación común de la fecha elegida
create or replace function public._fecha_colocacion_ok(s solicitudes, p_fecha date)
 returns date language plpgsql stable set search_path to 'public'
as $$
declare hoy date := (now() at time zone 'America/Tegucigalpa')::date;
begin
  if p_fecha is null then return hoy; end if;
  if p_fecha > hoy then raise exception 'La fecha de colocación no puede ser futura'; end if;
  if p_fecha < (s.creado_en at time zone 'America/Tegucigalpa')::date then
    raise exception 'La fecha de colocación no puede ser anterior a la solicitud (%)', to_char((s.creado_en at time zone 'America/Tegucigalpa')::date, 'DD/MM/YYYY');
  end if;
  return p_fecha;
end $$;

-- Desembolso por transferencia (analista) con fecha de colocación opcional
drop function if exists public.marcar_desembolsada(bigint, text);
create or replace function public.marcar_desembolsada(p_id bigint, p_referencia text, p_fecha date default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare s solicitudes; f date;
begin
  if not tiene_rol('analista') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'desembolso_pendiente' then raise exception 'La solicitud no está pendiente de desembolso'; end if;
  if length(trim(coalesce(p_referencia,''))) = 0 then raise exception 'Indique la referencia de la transferencia'; end if;
  f := _fecha_colocacion_ok(s, p_fecha);
  update solicitudes set estado = 'desembolsada', desembolso_referencia = trim(p_referencia),
    desembolsado_en = now(), desembolsado_por = auth.uid(), fecha_colocacion = f where id = p_id;
  perform _evento(p_id, 'desembolsada', 'desembolso_pendiente', 'desembolsada',
    p_referencia || case when f <> (now() at time zone 'America/Tegucigalpa')::date then ' · cuenta para el ' || to_char(f, 'DD/MM/YYYY') else '' end);
end $function$;

-- Cierre de verificación (efectivo entregado en campo) con fecha de colocación opcional
drop function if exists public.finalizar_verificacion(bigint, text, text);
create or replace function public.finalizar_verificacion(p_id bigint, p_resultado text, p_nota text default null, p_fecha date default null)
 returns text language plpgsql security definer set search_path to 'public'
as $function$
declare s solicitudes; pend int; destino text; v uuid; n int; f date;
begin
  if not tiene_rol('verificador') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'por_verificar' then raise exception 'La solicitud no está por verificar'; end if;
  if p_resultado = 'ok' then
    select count(*) into pend from verificacion_items i where i.solicitud_id = p_id and not i.completado and item_aplica(s, i.item);
    if pend > 0 then raise exception 'Faltan % ítem(s) por completar', pend; end if;
    destino := case when s.forma_desembolso = 'efectivo' then 'desembolsada' else 'desembolso_pendiente' end;
  elsif p_resultado = 'rechazada' then
    if length(trim(coalesce(p_nota,''))) = 0 then raise exception 'Indique el motivo'; end if;
    destino := 'rechazada_verificacion';
  else raise exception 'Resultado inválido'; end if;
  if destino = 'desembolsada' then f := _fecha_colocacion_ok(s, p_fecha); end if;
  v := coalesce(s.verificador_id, auth.uid());
  update solicitudes set estado = destino, verificacion_nota = nullif(trim(coalesce(p_nota,'')),''),
    verificado_en = now(), verificador_id = v,
    desembolsado_en = case when destino='desembolsada' then now() end,
    desembolsado_por = case when destino='desembolsada' then auth.uid() end,
    desembolso_referencia = case when destino='desembolsada' then 'Efectivo entregado en campo' end,
    fecha_colocacion = f
  where id = p_id;
  insert into visitas (solicitud_id, verificador_id, tipo, resultado, lat, lng, item_id, nombre_cliente)
  select p_id, auth.uid(), case when i.item = 'entrega_efectivo' then 'desembolso' else i.item end, p_resultado, i.lat, i.lng, i.id, s.nombre_cliente
  from verificacion_items i
  where i.solicitud_id = p_id and i.item in ('domicilio','trabajo','entrega_efectivo') and item_aplica(s, i.item)
    and (i.completado or i.foto_path is not null or i.lat is not null)
    and not (p_resultado = 'rechazada' and i.item = 'entrega_efectivo')
    and not exists (select 1 from visitas x where x.item_id = i.id);
  if p_resultado = 'rechazada' then update visitas set resultado = 'rechazada' where solicitud_id = p_id and tipo <> 'desembolso'; end if;
  select count(*) into n from visitas where solicitud_id = p_id;
  if n = 0 and p_resultado = 'rechazada' then
    insert into visitas (solicitud_id, verificador_id, tipo, resultado, nombre_cliente) values (p_id, auth.uid(), 'domicilio', 'rechazada', s.nombre_cliente);
  end if;
  perform _evento(p_id, 'verificacion_' || p_resultado, 'por_verificar', destino,
    nullif(concat_ws(' · ', nullif(trim(coalesce(p_nota,'')),''),
      case when f is not null and f <> (now() at time zone 'America/Tegucigalpa')::date then 'cuenta para el ' || to_char(f, 'DD/MM/YYYY') end), ''));
  return destino;
end $function$;

-- Cambiar el día en que cuenta una solicitud ya desembolsada (analista / admin)
create or replace function public.cambiar_fecha_colocacion(p_id bigint, p_fecha date, p_nota text default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare s solicitudes; f date;
begin
  if not tiene_rol('analista') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'desembolsada' then raise exception 'La solicitud no está desembolsada'; end if;
  if p_fecha is null then raise exception 'Indique la fecha'; end if;
  f := _fecha_colocacion_ok(s, p_fecha);
  if f is not distinct from s.fecha_colocacion then return; end if;
  update solicitudes set fecha_colocacion = f where id = p_id;
  insert into eventos (solicitud_id, usuario_id, accion, nota)
  values (p_id, auth.uid(), 'fecha_colocacion',
    'Cuenta para el ' || to_char(f, 'DD/MM/YYYY') || ' (antes ' || coalesce(to_char(s.fecha_colocacion, 'DD/MM/YYYY'), '—') || ')'
    || coalesce(' · ' || nullif(trim(coalesce(p_nota,'')),''), ''));
end $function$;

revoke all on function public.marcar_desembolsada(bigint, text, date) from public, anon;
revoke all on function public.finalizar_verificacion(bigint, text, text, date) from public, anon;
revoke all on function public.cambiar_fecha_colocacion(bigint, date, text) from public, anon;
revoke all on function public._fecha_colocacion_ok(solicitudes, date) from public, anon;
grant execute on function public.marcar_desembolsada(bigint, text, date) to authenticated;
grant execute on function public.finalizar_verificacion(bigint, text, text, date) to authenticated;
grant execute on function public.cambiar_fecha_colocacion(bigint, date, text) to authenticated;
grant execute on function public._fecha_colocacion_ok(solicitudes, date) to authenticated;

-- Día en que cuenta un desembolso (por si alguna fila no trae fecha_colocacion, ej. importadas)
create or replace function public.dia_colocacion(s solicitudes)
 returns date language sql stable set search_path to 'public'
as $$ select coalesce(s.fecha_colocacion, (coalesce(s.desembolsado_en, s.cerrado_en) at time zone 'America/Tegucigalpa')::date) $$;
grant execute on function public.dia_colocacion(solicitudes) to authenticated;

-- Estadísticas: desembolsos por fecha de colocación; las solicitudes en espera no suman como creadas
create or replace function public.estadisticas(p_desde date, p_hasta date)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare r jsonb; d0 timestamptz; d1 timestamptz; tz text := 'America/Tegucigalpa'; h0 date;
begin
  if mi_rol() is null then raise exception 'Sin permiso'; end if;
  d0 := (p_desde::timestamp) at time zone tz;
  d1 := ((p_hasta + 1)::timestamp) at time zone tz;
  h0 := (date_trunc('month', p_hasta - 8) - interval '5 months' + interval '8 days')::date;
  with base as (select * from solicitudes where creado_en >= d0 and creado_en < d1 and not coalesce(en_espera, false)),
  dict as (select * from solicitudes where dictamen_en >= d0 and dictamen_en < d1),
  des as (select s.*, capital_colocado(s) cap, dia_colocacion(s) dia
          from solicitudes s where estado='desembolsada' and dia_colocacion(s) between p_desde and p_hasta),
  des_hist as (select capital_colocado(s) cap, dia_colocacion(s) dia
          from solicitudes s where estado='desembolsada' and dia_colocacion(s) between least(h0, date_trunc('week', p_hasta::timestamp)::date - 28) and p_hasta),
  vis as (select v.*, p.nombre from visitas v join perfiles p on p.id = v.verificador_id where v.creado_en >= d0 and v.creado_en < d1)
  select jsonb_build_object(
    'creadas', (select count(*) from base),
    'por_tipo', (select coalesce(jsonb_object_agg(tipo, n),'{}') from (select tipo, count(*) n from base group by tipo) x),
    'por_estado_actual', (select coalesce(jsonb_object_agg(estado, n),'{}') from (select estado, count(*) n from solicitudes group by estado) x),
    'en_espera', (select count(*) from solicitudes where en_espera and estado not in ('desembolsada','denegada','rechazada_verificacion','desistida')),
    'aprobadas', (select count(*) from dict where estado <> 'denegada'),
    'denegadas', (select count(*) from dict where estado = 'denegada'),
    'desembolsadas', (select count(*) from des),
    'monto_desembolsado', (select coalesce(sum(cap),0) from des),
    'monto_prestamos', (select coalesce(sum(coalesce(monto_solicitado, monto_aprobado)),0) from des),
    'capital_refinanciado', (select coalesce(sum(least(coalesce(saldo_capital,0), coalesce(monto_solicitado, monto_aprobado, 0))),0) from des where tipo <> 'nuevo'),
    'colocado_por_tipo', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('n', n, 'capital', c, 'prestamos', pr)),'{}') from (
        select tipo, count(*) n, sum(cap) c, sum(coalesce(monto_solicitado, monto_aprobado)) pr from des group by tipo) x),
    'dias_activos', (select count(distinct dia) from des),
    'monto_aprobado', (select coalesce(sum(monto_aprobado),0) from dict where monto_aprobado is not null),
    'desembolso_efectivo', (select count(*) from des where forma_desembolso='efectivo'),
    'desembolso_transferencia', (select count(*) from des where forma_desembolso='transferencia'),
    'horas_analisis_prom', (select round(avg(extract(epoch from dictamen_en - enviado_analisis_en)/3600)::numeric,1) from dict where enviado_analisis_en is not null),
    'horas_ciclo_prom', (select round(avg(extract(epoch from desembolsado_en - creado_en)/3600)::numeric,1) from des),
    'por_dia', (select coalesce(jsonb_agg(x order by dia),'[]') from (
        select to_char(g::date,'YYYY-MM-DD') dia,
          (select count(*) from base b where (b.creado_en at time zone tz)::date = g::date) creadas,
          (select count(*) from des d where d.dia = g::date) desembolsadas,
          (select coalesce(sum(cap),0) from des d where d.dia = g::date) capital
        from generate_series(p_desde, p_hasta, interval '1 day') g) x),
    'semanas', (select coalesce(jsonb_agg(x order by ini),'[]') from (
        select to_char(w,'IW')::int semana, to_char(w,'YYYY-MM-DD') ini,
          (select coalesce(sum(cap),0) from des_hist h where h.dia >= w::date and h.dia < (w + interval '7 days')::date) capital,
          (select count(*) from des_hist h where h.dia >= w::date and h.dia < (w + interval '7 days')::date) n
        from generate_series(date_trunc('week', p_hasta::timestamp) - interval '4 weeks', date_trunc('week', p_hasta::timestamp), interval '1 week') w) x),
    'meses', (select coalesce(jsonb_agg(x order by mes),'[]') from (
        select to_char(m,'YYYY-MM') mes,
          (select coalesce(sum(cap),0) from des_hist h where date_trunc('month', h.dia - 8) = m) capital,
          (select count(*) from des_hist h where date_trunc('month', h.dia - 8) = m) n
        from generate_series(date_trunc('month', (p_hasta - 8)::timestamp) - interval '5 months', date_trunc('month', (p_hasta - 8)::timestamp), interval '1 month') m) x),
    'por_asesor', (select coalesce(jsonb_agg(x order by creadas desc),'[]') from (
        select p.nombre, count(*) creadas,
          count(*) filter (where b.estado='desembolsada') desembolsadas,
          count(*) filter (where b.estado in ('denegada','rechazada_verificacion')) rechazadas,
          coalesce(sum(capital_colocado(b)) filter (where b.estado='desembolsada'),0) monto
        from base b join perfiles p on p.id = b.asesor_id group by p.nombre) x),
    'por_verificador', (select coalesce(jsonb_agg(x order by n desc),'[]') from (
        select p.nombre, count(*) n,
          count(*) filter (where s.estado='rechazada_verificacion') rechazadas
        from solicitudes s join perfiles p on p.id = s.verificador_id
        where s.verificado_en >= d0 and s.verificado_en < d1 group by p.nombre) x),
    'visitas', (select coalesce(jsonb_agg(x order by total desc),'[]') from (
        select nombre, count(*) total,
          count(*) filter (where tipo='domicilio') domicilio,
          count(*) filter (where tipo='trabajo') trabajo,
          count(*) filter (where tipo='desembolso') desembolso,
          count(*) filter (where resultado='rechazada') rechazadas,
          count(distinct solicitud_id) solicitudes
        from vis group by nombre) x),
    'visitas_total', (select count(*) from vis),
    'motivos_denegacion', (select coalesce(jsonb_agg(x),'[]') from (
        select dictamen_nota nota, count(*) n from dict where estado='denegada' group by 1 order by 2 desc limit 8) x)
  ) into r;
  return r;
end $function$;

-- Ciclo promedio: desembolsadas según su día de colocación
create or replace function public.estadisticas_tiempos(p_desde date, p_hasta date)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare d0 timestamptz; d1 timestamptz; r jsonb;
begin
  if mi_rol() is null then raise exception 'Sin permiso'; end if;
  d0 := (p_desde::timestamp) at time zone 'America/Tegucigalpa';
  d1 := ((p_hasta + 1)::timestamp) at time zone 'America/Tegucigalpa';
  select jsonb_build_object(
    'por_paso', (select coalesce(jsonb_agg(x order by orden),'[]') from (
        select de_estado estado, count(*) n,
          round(avg(duracion_seg)) prom_seg, round(avg(duracion_habil_seg)) prom_habil_seg,
          max(duracion_habil_seg) max_habil_seg,
          array_position(array['borrador','en_analisis','aprobada','por_verificar','desembolso_pendiente'], de_estado) orden
        from eventos where creado_en >= d0 and creado_en < d1 and de_estado is not null
          and de_estado in ('borrador','en_analisis','aprobada','por_verificar','desembolso_pendiente')
        group by de_estado) x),
    'por_gestor', (select coalesce(jsonb_agg(x order by n desc),'[]') from (
        select p.nombre, p.rol, count(*) n, round(avg(e.duracion_habil_seg)) prom_habil_seg
        from eventos e join perfiles p on p.id = e.usuario_id
        where e.creado_en >= d0 and e.creado_en < d1 and e.de_estado is not null
          and e.accion not in ('desistida','regresada_revisadas')
        group by p.nombre, p.rol) x),
    'ciclo', (select jsonb_build_object(
        'n', count(*), 'prom_seg', round(avg(duracion_total_seg)), 'prom_habil_seg', round(avg(duracion_total_habil_seg)),
        'min_habil_seg', min(duracion_total_habil_seg), 'max_habil_seg', max(duracion_total_habil_seg),
        'dentro_meta', count(*) filter (where duracion_total_habil_seg <= p('meta_total_min') * 60))
        from solicitudes s where estado = 'desembolsada' and dia_colocacion(s) between p_desde and p_hasta)
  ) into r;
  return r;
end $function$;

-- Celebración de la meta diaria: suma por día de colocación
create or replace function private.meta_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare d date; w int; m numeric; c numeric; sec text;
begin
  if new.estado <> 'desembolsada' or old.estado = 'desembolsada' or coalesce(new.importado, false) then return null; end if;
  d := dia_colocacion(new);
  if d <> (now() at time zone 'America/Tegucigalpa')::date or exists (select 1 from celebraciones where dia = d) then return null; end if;
  w := extract(dow from d);
  if w = 0 or exists (select 1 from feriados where fecha = d) then return null; end if;
  m := coalesce((select valor::numeric from parametros where clave = case when w = 6 then 'meta_diaria_sab' else 'meta_diaria_lv' end),
                case when w = 6 then 20000 else 40000 end);
  if m <= 0 then return null; end if;
  select coalesce(sum(coalesce(capital_colocado_hist,
           case when tipo = 'nuevo' then coalesce(nullif(monto_solicitado, 0), monto_aprobado, 0)
                else greatest(0, coalesce(nullif(monto_solicitado, 0), monto_aprobado, 0) - coalesce(saldo_capital, 0)) end)), 0)
    into c from solicitudes s
   where estado = 'desembolsada' and dia_colocacion(s) = d;
  if c < m then return null; end if;
  insert into celebraciones (dia, monto, meta) values (d, c, m) on conflict (dia) do nothing;
  if not found then return null; end if;
  select v into sec from private.push_config where k = 'secreto';
  perform net.http_post(
    url := 'https://edmvfqelxsxevpmxgbav.supabase.co/functions/v1/push',
    body := jsonb_build_object('tabla', 'meta', 'dia', d, 'monto', c, 'meta', m),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-vc-secreto', sec),
    timeout_milliseconds := 10000);
  return null;
exception when others then
  return null;   -- nunca impide guardar el desembolso
end $$;

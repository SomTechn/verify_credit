-- 1) Tasa de interés fijada por el analista (mensual, en decimal: 0.12 = 12%). NULL = la automática.
alter table public.solicitudes add column if not exists tasa_nivelado numeric, add column if not exists tasa_solo_interes numeric;

create or replace function public.fijar_tasa(p_id bigint, p_nivelado numeric, p_solo_interes numeric)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare s solicitudes; txt text;
begin
  if not tiene_rol('analista') then raise exception 'Solo el analista puede fijar la tasa'; end if;
  s := _bloquear(p_id);
  if s.estado not in ('en_analisis','aprobada','por_verificar','desembolso_pendiente') then
    raise exception 'La tasa solo se puede cambiar desde el análisis hasta antes del desembolso'; end if;
  if (p_nivelado is not null and (p_nivelado <= 0 or p_nivelado > 0.5)) or (p_solo_interes is not null and (p_solo_interes <= 0 or p_solo_interes > 0.5)) then
    raise exception 'La tasa debe estar entre 0.01%% y 50%% mensual'; end if;
  if p_nivelado is not distinct from s.tasa_nivelado and p_solo_interes is not distinct from s.tasa_solo_interes then return; end if;
  update solicitudes set tasa_nivelado = round(p_nivelado, 6), tasa_solo_interes = round(p_solo_interes, 6) where id = p_id;
  txt := 'Nivelado: ' || coalesce(trim(to_char(p_nivelado * 100, 'FM990.99')) || '%', 'automática')
      || ' · Solo interés: ' || coalesce(trim(to_char(p_solo_interes * 100, 'FM990.99')) || '%', 'automática');
  perform _evento(p_id, 'ajuste_tasa', null, null, txt);
end $function$;
revoke all on function public.fijar_tasa(bigint, numeric, numeric) from public, anon;
grant execute on function public.fijar_tasa(bigint, numeric, numeric) to authenticated;

-- 2) Confirmar desembolso por transferencia sin número de referencia (opcional)
create or replace function public.marcar_desembolsada(p_id bigint, p_referencia text default null, p_fecha date default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare s solicitudes; f date; ref text := nullif(trim(coalesce(p_referencia,'')),'');
begin
  if not tiene_rol('analista') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'desembolso_pendiente' then raise exception 'La solicitud no está pendiente de desembolso'; end if;
  f := _fecha_colocacion_ok(s, p_fecha);
  update solicitudes set estado = 'desembolsada', desembolso_referencia = coalesce(ref, 'Transferencia confirmada'),
    desembolsado_en = now(), desembolsado_por = auth.uid(), fecha_colocacion = f where id = p_id;
  perform _evento(p_id, 'desembolsada', 'desembolso_pendiente', 'desembolsada',
    concat_ws(' · ', coalesce(ref, 'Transferencia confirmada'),
      case when f <> (now() at time zone 'America/Tegucigalpa')::date then 'cuenta para el ' || to_char(f, 'DD/MM/YYYY') end));
end $function$;

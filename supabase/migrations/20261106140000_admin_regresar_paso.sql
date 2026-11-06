-- El administrador puede regresar una solicitud a un paso anterior (ej. Completar datos → Análisis,
-- Verificación → Análisis o Asesor) o reabrir una cerrada en cualquier paso. Queda como paso en el historial
-- (evento paso_revertido con de/a estado) para que los tiempos sigan cuadrando.
create or replace function public.admin_regresar_paso(p_id bigint, p_destino text, p_motivo text)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare s solicitudes;
  pasos text[] := array['borrador','en_analisis','aprobada','por_verificar','desembolso_pendiente'];
  cerradas text[] := array['desembolsada','denegada','rechazada_verificacion','desistida'];
begin
  if coalesce(mi_rol(),'') <> 'admin' then raise exception 'Solo el administrador puede regresar pasos'; end if;
  if length(trim(coalesce(p_motivo,''))) = 0 then raise exception 'Indique el motivo'; end if;
  s := _bloquear(p_id);
  if not (p_destino = any(pasos)) then raise exception 'Paso no válido'; end if;
  if s.estado = p_destino then raise exception 'La solicitud ya está en ese paso'; end if;
  if s.estado = any(pasos) and array_position(pasos, p_destino) > array_position(pasos, s.estado) then
    raise exception 'Solo se puede regresar a un paso anterior'; end if;
  if p_destino = 'por_verificar' and not exists (select 1 from verificacion_items where solicitud_id = p_id) then
    raise exception 'La solicitud no tiene puntos de verificación: regrésela a Completar datos'; end if;
  if p_destino = 'desembolso_pendiente' and coalesce(s.forma_desembolso,'') <> 'transferencia' then
    raise exception 'Solo las solicitudes por transferencia pasan por Desembolso'; end if;
  if p_destino in ('aprobada','por_verificar','desembolso_pendiente') and s.monto_aprobado is null then
    raise exception 'La solicitud no tiene monto aprobado: regrésela a Análisis'; end if;

  update solicitudes set estado = p_destino,
    -- vuelve a análisis o captura: el analista dictamina de nuevo
    dictamen_en = case when p_destino in ('borrador','en_analisis') then null else dictamen_en end,
    -- deja de estar verificada / desembolsada / desistida
    verificado_en = case when p_destino <> 'desembolso_pendiente' then null else verificado_en end,
    verificacion_nota = case when s.estado = 'rechazada_verificacion' then null else verificacion_nota end,
    desembolsado_en = null, desembolsado_por = null, desembolso_referencia = null,
    motivo_cierre = case when s.estado = 'desistida' then null else motivo_cierre end
  where id = p_id;
  perform _evento(p_id, 'paso_revertido', s.estado, p_destino, trim(p_motivo));
end $function$;

revoke all on function public.admin_regresar_paso(bigint, text, text) from public, anon;
grant execute on function public.admin_regresar_paso(bigint, text, text) to authenticated;

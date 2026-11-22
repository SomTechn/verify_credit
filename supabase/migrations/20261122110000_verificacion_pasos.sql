-- Verificación paso a paso: el verificador marca "Voy en camino" y "Llegué" en cada lugar antes de marcarlo verificado.
alter table public.verificacion_items add column if not exists en_camino_en timestamptz;
alter table public.verificacion_items add column if not exists llegada_en timestamptz;
alter table public.verificacion_items add column if not exists llegada_lat double precision;
alter table public.verificacion_items add column if not exists llegada_lng double precision;

-- p_ts: hora en que lo marcó en el teléfono (si estaba sin señal y se envía después). Se acepta si es de las últimas 24 h.
create or replace function public.marcar_paso_verificacion(p_id bigint, p_item text, p_paso text,
  p_lat double precision default null, p_lng double precision default null, p_ts timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s solicitudes; it verificacion_items; t timestamptz := now();
begin
  if not tiene_rol('verificador') then raise exception 'Sin permiso'; end if;
  if p_item not in ('domicilio','trabajo') then raise exception 'Ese punto no tiene recorrido'; end if;
  if p_paso not in ('en_camino','llegada','deshacer') then raise exception 'Paso no válido'; end if;
  if p_ts is not null and p_ts <= now() and p_ts > now() - interval '24 hours' then t := p_ts; end if;
  select * into s from solicitudes where id = p_id;
  if s.id is null then raise exception 'Solicitud no encontrada'; end if;
  if s.estado <> 'por_verificar' and coalesce(mi_rol(),'') <> 'admin' then raise exception 'La solicitud no está por verificar'; end if;
  select * into it from verificacion_items where solicitud_id = p_id and item = p_item;
  if it.id is null then raise exception 'Ese punto no aplica para esta solicitud'; end if;
  if p_paso = 'en_camino' then
    update verificacion_items set en_camino_en = coalesce(en_camino_en, t), actualizado_por = auth.uid(), actualizado_en = now() where id = it.id returning * into it;
  elsif p_paso = 'llegada' then
    if it.en_camino_en is null then raise exception 'Primero marque "Voy en camino"'; end if;
    update verificacion_items set llegada_en = coalesce(llegada_en, greatest(t, en_camino_en)), llegada_lat = coalesce(p_lat, llegada_lat), llegada_lng = coalesce(p_lng, llegada_lng),
      actualizado_por = auth.uid(), actualizado_en = now() where id = it.id returning * into it;
  else
    if it.completado then raise exception 'Primero quite la marca de verificado'; end if;
    if it.llegada_en is not null then
      update verificacion_items set llegada_en = null, llegada_lat = null, llegada_lng = null, actualizado_por = auth.uid(), actualizado_en = now() where id = it.id returning * into it;
    else
      update verificacion_items set en_camino_en = null, actualizado_por = auth.uid(), actualizado_en = now() where id = it.id returning * into it;
    end if;
  end if;
  if s.verificador_id is null and s.estado = 'por_verificar' then update solicitudes set verificador_id = auth.uid() where id = p_id; end if;
  return to_jsonb(it);
end $$;
revoke all on function public.marcar_paso_verificacion(bigint, text, text, double precision, double precision, timestamptz) from public, anon;
grant execute on function public.marcar_paso_verificacion(bigint, text, text, double precision, double precision, timestamptz) to authenticated;

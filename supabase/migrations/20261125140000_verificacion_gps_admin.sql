-- Verificación tipo delivery: GPS y hora en cada paso (en camino, llegó, completada).
-- Las coordenadas solo las ve el administrador y quien él autorice en Usuarios (perfiles.ver_gps).

alter table public.verificacion_items
  add column if not exists en_camino_lat double precision,
  add column if not exists en_camino_lng double precision,
  add column if not exists completado_en timestamptz;
update public.verificacion_items set completado_en = actualizado_en where completado and completado_en is null;

alter table public.perfiles add column if not exists ver_gps boolean not null default false;

create or replace function public.puede_ver_gps() returns boolean
 language sql stable security definer set search_path to 'public' as $$
  select coalesce(mi_rol() = 'admin', false) or exists (select 1 from perfiles where id = auth.uid() and activo and ver_gps)
$$;

create or replace function public.fijar_ver_gps(p_id uuid, p_valor boolean) returns void
 language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador puede dar este permiso'; end if;
  update perfiles set ver_gps = coalesce(p_valor, false) where id = p_id;
end $$;

-- Coordenadas de los pasos (solo con permiso)
create or replace function public.verif_gps(p_ids bigint[])
 returns table(id bigint, solicitud_id bigint, item text, en_camino_lat double precision, en_camino_lng double precision,
               llegada_lat double precision, llegada_lng double precision, lat double precision, lng double precision)
 language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not puede_ver_gps() then raise exception 'Sin permiso para ver la ubicación de las verificaciones'; end if;
  return query select v.id, v.solicitud_id, v.item, v.en_camino_lat, v.en_camino_lng, v.llegada_lat, v.llegada_lng, v.lat, v.lng
    from verificacion_items v where v.solicitud_id = any(p_ids);
end $$;

create or replace function public.marcar_paso_verificacion(p_id bigint, p_item text, p_paso text, p_lat double precision default null, p_lng double precision default null, p_ts timestamptz default null)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
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
    update verificacion_items set en_camino_en = coalesce(en_camino_en, t),
      en_camino_lat = case when en_camino_en is null then p_lat else coalesce(en_camino_lat, p_lat) end,
      en_camino_lng = case when en_camino_en is null then p_lng else coalesce(en_camino_lng, p_lng) end,
      actualizado_por = auth.uid(), actualizado_en = now() where id = it.id returning * into it;
  elsif p_paso = 'llegada' then
    if it.en_camino_en is null then raise exception 'Primero marque "Voy en camino"'; end if;
    update verificacion_items set llegada_en = coalesce(llegada_en, greatest(t, en_camino_en)), llegada_lat = coalesce(p_lat, llegada_lat), llegada_lng = coalesce(p_lng, llegada_lng),
      actualizado_por = auth.uid(), actualizado_en = now() where id = it.id returning * into it;
  else
    if it.completado then raise exception 'Primero deshaga "Verificación completada"'; end if;
    if it.llegada_en is not null then
      update verificacion_items set llegada_en = null, llegada_lat = null, llegada_lng = null, actualizado_por = auth.uid(), actualizado_en = now() where id = it.id returning * into it;
    else
      update verificacion_items set en_camino_en = null, en_camino_lat = null, en_camino_lng = null, actualizado_por = auth.uid(), actualizado_en = now() where id = it.id returning * into it;
    end if;
  end if;
  if s.verificador_id is null and s.estado = 'por_verificar' then update solicitudes set verificador_id = auth.uid() where id = p_id; end if;
  -- No se devuelven coordenadas al teléfono del verificador
  return to_jsonb(it) - array['lat','lng','llegada_lat','llegada_lng','en_camino_lat','en_camino_lng'];
end $function$;

create or replace function public.guardar_item(p_id bigint, p_item text, p_completado boolean, p_nota text default null, p_foto text default null, p_lat double precision default null, p_lng double precision default null)
 returns void language plpgsql security definer set search_path to 'public' as $function$
declare s solicitudes; it verificacion_items; antes boolean;
begin
  if not tiene_rol('verificador') then raise exception 'Sin permiso'; end if;
  select * into s from solicitudes where id = p_id;
  if s.estado <> 'por_verificar' and coalesce(mi_rol(),'') <> 'admin' then raise exception 'La solicitud no está por verificar'; end if;
  select completado into antes from verificacion_items where solicitud_id = p_id and item = p_item;
  update verificacion_items set completado = p_completado, nota = nullif(trim(coalesce(p_nota,'')),''),
    foto_path = coalesce(p_foto, foto_path),
    lat = case when p_completado then coalesce(p_lat, lat) else null end,
    lng = case when p_completado then coalesce(p_lng, lng) else null end,
    completado_en = case when p_completado then (case when coalesce(antes, false) then coalesce(completado_en, now()) else now() end) else null end,
    actualizado_por = auth.uid(), actualizado_en = now()
  where solicitud_id = p_id and item = p_item
  returning * into it;
  if it.id is null then raise exception 'Ese punto no aplica para esta solicitud'; end if;
  if p_completado then
    if exists (select 1 from visitas where item_id = it.id) then
      update visitas set lat = coalesce(it.lat, lat), lng = coalesce(it.lng, lng), resultado = 'ok' where item_id = it.id;
    else
      insert into visitas (solicitud_id, verificador_id, tipo, resultado, lat, lng, item_id, nombre_cliente)
      values (p_id, auth.uid(), case when it.item = 'entrega_efectivo' then 'desembolso' else it.item end, 'ok', it.lat, it.lng, it.id, s.nombre_cliente);
    end if;
  else
    delete from visitas where item_id = it.id;
  end if;
  if s.verificador_id is null and s.estado = 'por_verificar' then update solicitudes set verificador_id = auth.uid() where id = p_id; end if;
end $function$;

-- Visitas del período (conteo por día para analistas); las coordenadas solo van al admin o a quien tenga permiso
create or replace function public.visitas_mapa(p_desde date, p_hasta date)
 returns table(id bigint, solicitud_id bigint, codigo text, cliente text, tipo text, resultado text, verificador_id uuid, verificador text, lat double precision, lng double precision, creado_en timestamptz)
 language plpgsql stable security definer set search_path to 'public' as $function$
declare g boolean := puede_ver_gps();
begin
  if not tiene_rol('analista') and not g then raise exception 'Sin permiso'; end if;
  return query
  select v.id, v.solicitud_id, s.codigo, coalesce(v.nombre_cliente, s.nombre_cliente), v.tipo, v.resultado, v.verificador_id, p.nombre,
    case when g then v.lat end, case when g then v.lng end, v.creado_en
  from visitas v left join solicitudes s on s.id = v.solicitud_id left join perfiles p on p.id = v.verificador_id
  where (v.creado_en at time zone 'America/Tegucigalpa')::date between p_desde and p_hasta
  order by v.creado_en;
end $function$;

grant execute on function public.puede_ver_gps(), public.fijar_ver_gps(uuid, boolean), public.verif_gps(bigint[]) to authenticated;

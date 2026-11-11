-- Seguimiento reprogramado y alertas de solicitudes con más de N horas pendientes (11-nov-2026). Ya aplicada en la base.
alter table public.solicitudes
  add column if not exists seguimiento_en timestamptz,
  add column if not exists seguimiento_nota text,
  add column if not exists seguimiento_por uuid,
  add column if not exists seguimiento_avisado_en timestamptz,
  add column if not exists vigente_en timestamptz,
  add column if not exists vigente_por uuid;

insert into public.parametros (clave, valor, descripcion)
select 'alerta_horas', 48, 'Alertas: horas desde que se creó una solicitud para avisar que sigue pendiente'
where not exists (select 1 from public.parametros where clave = 'alerta_horas');

-- Al cambiar de paso se limpia el seguimiento (ya se atendió)
create or replace function public.tg_espera_categoria() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if not coalesce(new.en_espera, false) then new.espera_categoria := null; end if;
  if new.estado is distinct from old.estado then
    new.seguimiento_en := null; new.seguimiento_nota := null; new.seguimiento_por := null; new.seguimiento_avisado_en := null;
  end if;
  return new;
end $$;

create or replace function public.programar_seguimiento(p_id bigint, p_cuando timestamptz, p_nota text default null, p_espera boolean default true)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes; v_txt text; v_nota text := nullif(trim(coalesce(p_nota, '')), '');
begin
  if not tiene_rol('asesor','analista','verificador') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado in ('desembolsada','denegada','rechazada_verificacion','desistida') then raise exception 'La solicitud ya está cerrada'; end if;
  if p_cuando is null or p_cuando < now() - interval '1 minute' then raise exception 'Elija una fecha y hora que todavía no haya pasado'; end if;
  if p_cuando > now() + interval '60 days' then raise exception 'El seguimiento no puede ser a más de 60 días'; end if;
  v_txt := to_char(p_cuando at time zone 'America/Tegucigalpa', 'DD/MM/YYYY HH12:MI AM');
  update solicitudes set seguimiento_en = p_cuando, seguimiento_nota = v_nota, seguimiento_por = auth.uid(), seguimiento_avisado_en = null where id = p_id;
  if coalesce(p_espera, true) and not coalesce(s.en_espera, false) then
    update solicitudes set en_espera = true, espera_categoria = 'cliente_ausente',
      espera_motivo = concat_ws(' · ', 'Cliente no está / vuelve después', 'seguimiento ' || v_txt, v_nota),
      espera_desde = now(), espera_por = auth.uid() where id = p_id;
    perform _evento(p_id, 'en_espera', null, null, concat_ws(' · ', 'Cliente no está / vuelve después', 'seguimiento ' || v_txt, v_nota));
  end if;
  perform _evento(p_id, 'seguimiento_programado', null, null, concat_ws(' · ', v_txt, v_nota));
end $$;

create or replace function public.seguimiento_hecho(p_id bigint, p_nota text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes;
begin
  if not tiene_rol('asesor','analista','verificador') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.seguimiento_en is null then raise exception 'La solicitud no tiene seguimiento programado'; end if;
  update solicitudes set seguimiento_en = null, seguimiento_nota = null, seguimiento_por = null, seguimiento_avisado_en = null,
    vigente_en = now(), vigente_por = auth.uid() where id = p_id;
  perform _evento(p_id, 'seguimiento_hecho', null, null, p_nota);
end $$;

create or replace function public.confirmar_vigente(p_id bigint, p_nota text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes;
begin
  if not tiene_rol('asesor','analista') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado in ('desembolsada','denegada','rechazada_verificacion','desistida') then raise exception 'La solicitud ya está cerrada'; end if;
  update solicitudes set vigente_en = now(), vigente_por = auth.uid() where id = p_id;
  perform _evento(p_id, 'confirmada_vigente', null, null, p_nota);
end $$;

revoke all on function public.programar_seguimiento(bigint, timestamptz, text, boolean) from public, anon;
revoke all on function public.seguimiento_hecho(bigint, text) from public, anon;
revoke all on function public.confirmar_vigente(bigint, text) from public, anon;
grant execute on function public.programar_seguimiento(bigint, timestamptz, text, boolean) to authenticated, service_role;
grant execute on function public.seguimiento_hecho(bigint, text) to authenticated, service_role;
grant execute on function public.confirmar_vigente(bigint, text) to authenticated, service_role;

-- Aviso push armado por la base: va solo a las personas indicadas (evento 'directo' de la función push)
create or replace function private.push_directo(p_ids uuid[], p_titulo text, p_cuerpo text, p_id bigint default null, p_k text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare sec text;
begin
  select v into sec from private.push_config where k = 'secreto';
  perform net.http_post(
    url := 'https://edmvfqelxsxevpmxgbav.supabase.co/functions/v1/push',
    body := jsonb_build_object('tabla', 'directo', 'ids', to_jsonb(p_ids), 'titulo', p_titulo, 'cuerpo', p_cuerpo, 'id', p_id, 'k', p_k),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-vc-secreto', sec),
    timeout_milliseconds := 10000);
exception when others then null;
end $$;

-- Cada 5 minutos: avisa al asesor (y a quien lo programó) cuando llega la hora del seguimiento
create or replace function private.avisar_seguimientos() returns void
language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  for r in select id, nombre_cliente, codigo, asesor_id, seguimiento_por, seguimiento_nota from solicitudes
           where seguimiento_en is not null and seguimiento_en <= now() and seguimiento_avisado_en is null
             and estado in ('borrador','en_analisis','aprobada','por_verificar','desembolso_pendiente')
           order by seguimiento_en limit 50
  loop
    perform private.push_directo(array_remove(array[r.asesor_id, r.seguimiento_por], null),
      '📅 Seguimiento: ' || r.nombre_cliente, coalesce(r.seguimiento_nota, 'Es hora de volver a contactar al cliente') || ' · ' || r.codigo, r.id, 'seg-' || r.id);
    update solicitudes set seguimiento_avisado_en = now() where id = r.id;
  end loop;
end $$;

-- Lunes a sábado 8:40 a. m.: resumen al asesor de sus solicitudes con más de N horas sin confirmar ni reprogramar
create or replace function private.avisar_viejas() returns void
language plpgsql security definer set search_path to 'public' as $$
declare r record; h numeric := coalesce(p('alerta_horas'), 48);
begin
  for r in select asesor_id, count(*) n from solicitudes
           where estado in ('borrador','en_analisis','aprobada','por_verificar','desembolso_pendiente') and not coalesce(importado, false)
             and asesor_id is not null and seguimiento_en is null
             and creado_en < now() - make_interval(hours => h::int)
             and (vigente_en is null or vigente_en < now() - make_interval(hours => h::int))
           group by asesor_id
  loop
    perform private.push_directo(array[r.asesor_id], '⚠️ ' || r.n || ' solicitud(es) con más de ' || h::int || ' horas pendientes',
      'Confirme si se van a realizar, reprograme el seguimiento o ciérrelas. Están en la pestaña Alertas.', null, 'viejas');
  end loop;
end $$;

select cron.unschedule(jobname) from cron.job where jobname in ('vc_seguimientos', 'vc_viejas');
select cron.schedule('vc_seguimientos', '*/5 * * * *', 'select private.avisar_seguimientos()');
select cron.schedule('vc_viejas', '40 14 * * 1-6', 'select private.avisar_viejas()');

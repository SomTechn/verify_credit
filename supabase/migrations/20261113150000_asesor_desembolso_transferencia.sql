-- El asesor también puede confirmar desembolsos por transferencia (13-nov-2026)
create or replace function public.marcar_desembolsada(p_id bigint, p_referencia text default null, p_fecha date default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare s solicitudes; f date; ref text := nullif(trim(coalesce(p_referencia,'')),'');
begin
  if not tiene_rol('analista','asesor') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'desembolso_pendiente' then raise exception 'La solicitud no está pendiente de desembolso'; end if;
  f := _fecha_colocacion_ok(s, p_fecha);
  update solicitudes set estado = 'desembolsada', desembolso_referencia = coalesce(ref, 'Transferencia confirmada'),
    desembolsado_en = now(), desembolsado_por = auth.uid(), fecha_colocacion = f where id = p_id;
  perform _evento(p_id, 'desembolsada', 'desembolso_pendiente', 'desembolsada',
    concat_ws(' · ', coalesce(ref, 'Transferencia confirmada'),
      case when f <> (now() at time zone 'America/Tegucigalpa')::date then 'cuenta para el ' || to_char(f, 'DD/MM/YYYY') end));
end $function$;
revoke all on function public.marcar_desembolsada(bigint, text, date) from public, anon;
grant execute on function public.marcar_desembolsada(bigint, text, date) to authenticated, service_role;

-- Interruptor que la app lee: con 1 el asesor ve la pestaña Desembolsos y el botón "Confirmar desembolso"
insert into public.parametros (clave, valor, descripcion)
select 'asesor_desembolsa', 1, 'El asesor puede confirmar desembolsos por transferencia (1 = sí, 0 = no)'
where not exists (select 1 from public.parametros where clave = 'asesor_desembolsa');

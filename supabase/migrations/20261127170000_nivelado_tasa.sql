-- Cámbiate a nivelado (27-nov-2026, 4): el gestor puede cambiar la tasa nivelada de la proyección.
-- Si elige una tasa distinta de la normal (14%) queda fijada en la solicitud (tasa_nivelado); el analista la puede cambiar.
drop function if exists public.niv_crear_solicitud(bigint, text, text, numeric, int, text, numeric, text);

create or replace function public.niv_crear_solicitud(p_id bigint, p_dni text, p_telefono text default null,
  p_monto numeric default null, p_plazo int default null, p_nota text default null, p_monto_extra numeric default null,
  p_tipo_pago text default null, p_tasa numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p niv_prestamos; s solicitudes; a solicitudes; v_dni text := regexp_replace(coalesce(p_dni,''), '\D', '', 'g');
  v_id bigint; v_asesor uuid; v_tp text; v_txt text; c text[]; v_int numeric; v_tot numeric; v_monto numeric;
begin
  select * into p from niv_prestamos where id = p_id for update;
  if p.id is null then raise exception 'Préstamo no encontrado'; end if;
  if not _niv_puede(p) then raise exception 'Este cliente no es de su cartera'; end if;
  if length(v_dni) <> 13 then raise exception 'Ingrese el número de identidad (13 dígitos)'; end if;
  if p_plazo is not null and (p_plazo < 1 or p_plazo > 60) then raise exception 'Plazo no válido'; end if;
  v_int := coalesce(p.balance_cuotas, 0) + coalesce(p.balance_mora, 0);
  v_tot := coalesce(p.balance_capital, 0) + v_int;
  v_monto := round(coalesce(p_monto, v_tot + coalesce(p_monto_extra, 0)), 2);
  if v_monto <= 0 then raise exception 'Monto no válido'; end if;
  if p.solicitud_id is not null then
    select * into s from solicitudes where id = p.solicitud_id;
    if s.id is not null and s.estado not in ('denegada','rechazada_verificacion','desistida') then
      raise exception 'Ya se generó la solicitud % para este préstamo', s.codigo;
    end if;
  end if;
  select * into a from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni
     and estado not in ('desembolsada','denegada','rechazada_verificacion','desistida') and not coalesce(importado,false)
   order by creado_en desc limit 1;
  if a.id is not null then raise exception 'Este cliente ya tiene la solicitud % en proceso', a.codigo; end if;

  v_asesor := case when coalesce(mi_rol(),'') = 'asesor' then auth.uid() else _asesor_para_gestor() end;
  if p_tasa is not null and (p_tasa <= 0 or p_tasa > 0.5) then raise exception 'Tasa no válida'; end if;
  if p_tipo_pago is not null and p_tipo_pago not in ('Semanal','Quincenal','Mensual') then raise exception 'Forma de pago no válida'; end if;
  v_tp := coalesce(p_tipo_pago, case when upper(coalesce(p.tipo,'')) like '%SEMANAL%' then 'Semanal' when upper(coalesce(p.tipo,'')) like '%MENSUAL%' then 'Mensual' else 'Quincenal' end);

  insert into solicitudes (nombre_cliente, tipo, telefono, asesor_id, dni, cartera_id, creado_por, plan_pago, tipo_pago,
                           saldo_capital, saldo_intereses, monto_solicitado, plazo_meses, campana, tasa_nivelado)
  values (p.nombre, 'cambio_modalidad', coalesce(nullif(trim(coalesce(p_telefono,'')),''), p.telefono), v_asesor,
          substr(v_dni,1,4) || '-' || substr(v_dni,5,4) || '-' || substr(v_dni,9,5), p.cartera_id, auth.uid(), 'nivelado', v_tp,
          p.balance_capital, v_int, v_monto, p_plazo, 'nivelado',
          case when p_tasa is not null and abs(p_tasa - 0.14) > 0.000001 then round(p_tasa, 6) end)
  returning id into v_id;
  perform _evento(v_id, 'creada', null, 'borrador', 'Campaña Cámbiate a nivelado');
  c := copiar_datos_cliente(v_id);

  v_txt := 'Campaña Cámbiate a nivelado. Préstamo solo interés del ' || to_char(p.fecha, 'DD/MM/YYYY')
    || ' por L ' || to_char(p.capital, 'FM999,999,990') || coalesce(', ' || p.tipo, '') || coalesce(', ' || p.dia_pago, '') || '. '
    || 'Saldo de capital L ' || to_char(coalesce(p.balance_capital,0), 'FM999,999,990.00')
    || ' + intereses acumulados L ' || to_char(coalesce(p.balance_cuotas,0), 'FM999,999,990.00')
    || case when coalesce(p.balance_mora,0) > 0 then ' + mora L ' || to_char(p.balance_mora, 'FM999,999,990.00') else '' end
    || ' = L ' || to_char(v_tot, 'FM999,999,990.00') || '. Monto solicitado L ' || to_char(v_monto, 'FM999,999,990.00')
    || case when p_plazo is not null then ' a ' || p_plazo || ' meses' else '' end || ', pago ' || lower(v_tp)
    || case when p_tasa is not null then ', tasa ' || trim(trailing '.' from to_char(p_tasa * 100, 'FM990.99')) || '% mensual' else '' end || '.'
    || coalesce(' ' || nullif(trim(coalesce(p_nota,'')),''), '');
  insert into comentarios (solicitud_id, autor_id, texto) values (v_id, auth.uid(), v_txt);

  insert into niv_gestiones (prestamo_id, resultado, nota, monto_extra, solicitud_id)
  values (p.id, 'solicitud', nullif(trim(coalesce(p_nota,'')),''), greatest(v_monto - v_tot, 0), v_id);
  update niv_prestamos set solicitud_id = v_id, resultado = 'solicitud', resultado_en = now(), resultado_por = auth.uid(),
    seguimiento_en = null, monto_extra = greatest(v_monto - v_tot, 0), gestiones = gestiones + 1,
    dni = substr(v_dni,1,4) || '-' || substr(v_dni,5,4) || '-' || substr(v_dni,9,5),
    telefono = coalesce(nullif(trim(coalesce(p_telefono,'')),''), telefono), actualizado_en = now()
  where id = p.id;
  return jsonb_build_object('id', v_id, 'codigo', (select codigo from solicitudes where id = v_id), 'copiados', to_jsonb(c));
end $$;

revoke all on function public.niv_crear_solicitud(bigint, text, text, numeric, int, text, numeric, text, numeric) from public, anon;
grant execute on function public.niv_crear_solicitud(bigint, text, text, numeric, int, text, numeric, text, numeric) to authenticated;

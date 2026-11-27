-- La hoja de solicitud es obligatoria para enviar a análisis las solicitudes NUEVAS creadas desde el 27-nov-2026 12:05 (hora HN).
-- Las que ya estaban en curso antes de esa hora quedan exentas.
create or replace function public.hoja_faltan(s solicitudes) returns text[]
language plpgsql stable set search_path to 'public' as $$
declare h jsonb := coalesce(s.datos_cliente->'hoja', '{}'::jsonb); f text[] := '{}'; r jsonb; i int;
  vacio constant text := '';
begin
  if coalesce(h->>'monto', vacio) = vacio then f := f || 'Cantidad solicitada'::text; end if;
  if s.plazo_meses is null then f := f || 'Plazo'::text; end if;
  if coalesce(h->>'nac', vacio) = vacio then f := f || 'Fecha de nacimiento'::text; end if;
  if coalesce(h->>'sexo', vacio) = vacio then f := f || 'Sexo'::text; end if;
  if coalesce(s.telefono, vacio) = vacio then f := f || 'Teléfono del cliente'::text; end if;
  if coalesce(h->>'empresa', vacio) = vacio then f := f || 'Empresa'::text; end if;
  if coalesce(h->>'rubro', vacio) = vacio then f := f || 'Rubro de la empresa'::text; end if;
  if coalesce(h#>>'{trab,ciudad}', vacio) = vacio or coalesce(h#>>'{trab,colonia}', vacio) = vacio then f := f || 'Dirección de la empresa (ciudad y colonia)'::text; end if;
  if coalesce(h->>'puesto', vacio) = vacio then f := f || 'Puesto'::text; end if;
  if coalesce(h#>>'{emp_desde,f}', vacio) = vacio then f := f || 'Antigüedad en la empresa'::text; end if;
  if coalesce(h->>'salario', vacio) = vacio then f := f || 'Cuánto gana'::text; end if;
  if coalesce(h->>'prest', vacio) = vacio then f := f || 'Prestaciones laborales'::text; end if;
  if coalesce(h->>'fpago', vacio) = vacio then f := f || 'Forma de pago'::text; end if;
  if coalesce(h->>'dia', vacio) = vacio then f := f || 'Día de cobro'::text; end if;
  if coalesce(h#>>'{dom,ciudad}', vacio) = vacio or coalesce(h#>>'{dom,colonia}', vacio) = vacio then f := f || 'Domicilio (ciudad y colonia)'::text; end if;
  if coalesce(h#>>'{dom,ref}', vacio) = vacio then f := f || 'Punto de referencia del domicilio'::text; end if;
  if coalesce(h#>>'{dom_desde,f}', vacio) = vacio then f := f || 'Antigüedad en el domicilio'::text; end if;
  if coalesce(h->>'vivienda', vacio) = vacio then f := f || 'Tipo de vivienda'::text; end if;
  for i in 0..1 loop
    r := case when jsonb_typeof(h->'refs') = 'array' then h->'refs'->i else null end;
    if r is null or coalesce(r->>'nombre', vacio) = vacio or coalesce(r->>'par', vacio) = vacio or coalesce(r->>'tel', vacio) = vacio then
      f := f || ('Referencia ' || (i + 1) || ' (nombre, parentesco y teléfono)')::text; end if;
  end loop;
  return f;
end $$;

create or replace function public.enviar_analisis(p_id bigint)
 returns void language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes; n int; fal text[];
begin
  if not tiene_rol('asesor') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'borrador' then raise exception 'La solicitud ya no está en borrador'; end if;
  if s.tipo = 'nuevo' then
    select count(*) into n from ingresos where solicitud_id = p_id and categoria = 'salario';
    if n = 0 then raise exception 'Agregue al menos un ingreso (salario) antes de enviar a análisis'; end if;
    if s.creado_en >= timestamptz '2026-11-27 18:05:00+00' then
      fal := hoja_faltan(s);
      if cardinality(fal) > 0 then raise exception 'Complete la hoja de solicitud antes de enviar a análisis. Falta: %', array_to_string(fal, ', '); end if;
    end if;
  end if;
  update solicitudes set estado = 'en_analisis', enviado_analisis_en = now() where id = p_id;
  perform _evento(p_id, 'enviada_analisis', 'borrador', 'en_analisis', null);
end $$;

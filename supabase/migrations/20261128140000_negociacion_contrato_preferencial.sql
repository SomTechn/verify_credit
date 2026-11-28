-- Cambio de modalidad y reestructuración: negociación confirmada por el analista + contrato firmado obligatorio.
-- Cartera preferencial: sin opción a refinanciamiento.
alter table solicitudes add column if not exists condonacion_monto numeric;
alter table solicitudes add column if not exists condonacion_nota text;
alter table solicitudes add column if not exists negociacion_confirmada_en timestamptz;
alter table solicitudes add column if not exists negociacion_confirmada_por uuid;

alter table carteras add column if not exists sin_refinanciamiento boolean not null default false;
insert into carteras (id, nombre, sin_refinanciamiento)
select 5, 'Preferencial', true where not exists (select 1 from carteras where id = 5 or nombre = 'Preferencial');
update carteras set sin_refinanciamiento = true where nombre = 'Preferencial';

create or replace function _cliente_preferencial(p_dni text, p_cartera smallint default null) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from carteras c where c.sin_refinanciamiento and c.id = p_cartera)
      or exists (select 1 from niv_prestamos n join carteras c on c.id = n.cartera_id
                  where c.sin_refinanciamiento and regexp_replace(coalesce(n.dni,''),'\D','','g') = regexp_replace(coalesce(p_dni,''),'\D','','g')
                    and length(regexp_replace(coalesce(p_dni,''),'\D','','g')) = 13)
$$;

create or replace function guardar_negociacion(p_id bigint, p_datos jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes; v_tasa numeric;
begin
  if not puede_editar_ingresos(p_id) then raise exception 'No puede editar esta solicitud en su estado actual'; end if;
  select * into s from solicitudes where id = p_id;
  if s.tipo not in ('cambio_modalidad','reestructuracion') then raise exception 'Solo aplica a cambio de modalidad y reestructuración'; end if;
  if p_datos ? 'tasa_nivelado' and nullif(p_datos->>'tasa_nivelado','') is not null then
    v_tasa := (p_datos->>'tasa_nivelado')::numeric;
    if v_tasa <= 0 or v_tasa > 0.5 then raise exception 'Tasa no válida'; end if;
  end if;
  update solicitudes set
    plazo_meses      = case when p_datos ? 'plazo_meses'      then nullif(p_datos->>'plazo_meses','')::int else plazo_meses end,
    tasa_nivelado    = case when p_datos ? 'tasa_nivelado'    then nullif(p_datos->>'tasa_nivelado','')::numeric else tasa_nivelado end,
    saldo_capital    = case when p_datos ? 'saldo_capital'    then nullif(p_datos->>'saldo_capital','')::numeric else saldo_capital end,
    saldo_intereses  = case when p_datos ? 'saldo_intereses'  then nullif(p_datos->>'saldo_intereses','')::numeric else saldo_intereses end,
    condonacion_monto= case when p_datos ? 'condonacion_monto'then nullif(p_datos->>'condonacion_monto','')::numeric else condonacion_monto end,
    condonacion_nota = case when p_datos ? 'condonacion_nota' then nullif(trim(p_datos->>'condonacion_nota'),'') else condonacion_nota end,
    monto_solicitado = case when p_datos ? 'monto_solicitado' then nullif(p_datos->>'monto_solicitado','')::numeric else monto_solicitado end
  where id = p_id;
end $$;

create or replace function guardar_contrato_firmado(p_id bigint, p_path text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes;
begin
  if mi_rol() is null then raise exception 'Sin permiso'; end if;
  select * into s from solicitudes where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if s.estado in ('borrador','en_analisis','denegada') and not (s.estado = 'borrador' and s.tipo in ('cambio_modalidad','reestructuracion')) then
    raise exception 'El contrato se sube desde que la solicitud está aprobada'; end if;
  if coalesce(p_path,'') not like p_id || '/contrato-firmado-%' then raise exception 'Archivo inválido'; end if;
  update solicitudes set contrato_firmado_path = p_path, contrato_firmado_en = now(), contrato_firmado_por = auth.uid() where id = p_id;
  perform _evento(p_id, 'contrato_firmado', null, null, 'Foto del contrato firmado');
end $$;

create or replace function enviar_analisis(p_id bigint) returns void
language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes; n int; fal text[];
begin
  if not tiene_rol('asesor') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado <> 'borrador' then raise exception 'La solicitud ya no está en borrador'; end if;
  if s.tipo = 'refinanciamiento' and _cliente_preferencial(s.dni, s.cartera_id) then
    raise exception 'Los clientes de la cartera preferencial no tienen opción a refinanciamiento'; end if;
  if s.tipo = 'nuevo' then
    select count(*) into n from ingresos where solicitud_id = p_id and categoria = 'salario';
    if n = 0 then raise exception 'Agregue al menos un ingreso (salario) antes de enviar a análisis'; end if;
    if s.creado_en >= timestamptz '2026-11-27 18:05:00+00' then
      fal := hoja_faltan(s);
      if cardinality(fal) > 0 then raise exception 'Complete la hoja de solicitud antes de enviar a análisis. Falta: %', array_to_string(fal, ', '); end if;
    end if;
  elsif s.tipo in ('cambio_modalidad','reestructuracion') then
    if s.plazo_meses is null or s.saldo_capital is null or s.saldo_intereses is null or (s.tipo = 'reestructuracion' and s.tasa_nivelado is null) then
      raise exception 'Complete los datos de la negociación: plazo, tasa, capital e intereses'; end if;
    if s.contrato_firmado_path is null then raise exception 'Suba el contrato firmado para enviar la solicitud a análisis'; end if;
  end if;
  update solicitudes set estado = 'en_analisis', enviado_analisis_en = now() where id = p_id;
  perform _evento(p_id, 'enviada_analisis', 'borrador', 'en_analisis', null);
end $$;

create or replace function crear_solicitud(p_nombre text, p_tipo text default 'nuevo', p_telefono text default null, p_enviar boolean default false, p_fecha_ingreso date default null, p_asesor uuid default null, p_dni text default null) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_asesor uuid := auth.uid(); v_dni text := regexp_replace(coalesce(p_dni,''),'\D','','g');
begin
  if not tiene_rol('asesor') then raise exception 'Solo el asesor puede crear solicitudes'; end if;
  if length(trim(coalesce(p_nombre,''))) < 3 then raise exception 'Nombre del cliente requerido'; end if;
  if length(v_dni) <> 13 then raise exception 'Ingrese el número de identidad (13 dígitos)'; end if;
  if p_fecha_ingreso is not null and p_fecha_ingreso > (now() at time zone 'America/Tegucigalpa')::date then
    raise exception 'La fecha de ingreso no puede ser futura'; end if;
  if p_tipo = 'refinanciamiento' and _cliente_preferencial(v_dni) then
    raise exception 'Los clientes de la cartera preferencial no tienen opción a refinanciamiento'; end if;
  if p_asesor is not null and p_asesor <> auth.uid() then
    if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador puede asignar otro asesor'; end if;
    if not exists (select 1 from perfiles where id = p_asesor and rol in ('asesor','admin') and activo) then
      raise exception 'El usuario seleccionado no es asesor activo'; end if;
    v_asesor := p_asesor;
  end if;
  if p_tipo = 'cambio_modalidad' then v_asesor := coalesce(_asesor_cambio_modalidad(), v_asesor); end if;
  insert into solicitudes (nombre_cliente, tipo, telefono, asesor_id, fecha_ingreso, dni, creado_por)
  values (trim(p_nombre), p_tipo, nullif(trim(coalesce(p_telefono,'')),''), v_asesor, p_fecha_ingreso,
          substr(v_dni,1,4) || '-' || substr(v_dni,5,4) || '-' || substr(v_dni,9,5), auth.uid())
  returning id into v_id;
  perform _evento(v_id, 'creada', null, 'borrador', null);
  if p_enviar and p_tipo not in ('cambio_modalidad','reestructuracion') then perform enviar_analisis(v_id); end if;
  return v_id;
end $$;

-- Cámbiate a nivelado: la solicitud queda en borrador con el asesor (Kevin) hasta confirmar la negociación y subir el contrato firmado
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'niv_crear_solicitud';
  d := replace(d, E'  update solicitudes set estado = ''en_analisis'', enviado_analisis_en = now() where id = v_id;\n', '');
  d := replace(d, E'  perform _evento(v_id, ''enviada_analisis'', ''borrador'', ''en_analisis'', ''Cambio de modalidad: pasa directo a análisis'');\n', '');
  if d like '%pasa directo a análisis%' then raise exception 'No se pudo parchear niv_crear_solicitud'; end if;
  execute d;
end $$;

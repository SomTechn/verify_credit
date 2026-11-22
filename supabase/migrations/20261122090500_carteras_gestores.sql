-- Carteras, gestores de cobro, rol extra de gerente y búsqueda del cliente por identidad.

-- ---------- Carteras ----------
create table if not exists public.carteras (
  id smallint primary key,
  nombre text not null unique,
  activa boolean not null default true,
  orden smallint not null default 0
);
insert into public.carteras (id, nombre, orden) values
  (1, 'Cartera', 1), (2, 'Gestión Telefónica', 2), (3, 'Gestión Presencial', 3), (4, 'Gestión Telefónica #2', 4)
on conflict (id) do nothing;
alter table public.carteras enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='carteras' and policyname='carteras_sel') then
    create policy carteras_sel on public.carteras for select to authenticated using ((select mi_rol()) is not null);
  end if;
end $$;

-- Perfiles: carteras asignadas (gestores) y roles adicionales (p. ej. gerente)
alter table public.perfiles add column if not exists carteras smallint[] not null default '{}';
alter table public.perfiles add column if not exists roles_extra text[] not null default '{}';

-- Los gestores no tienen acceso general: mi_rol() es nulo para ellos, así todas las
-- políticas "mi_rol() is not null" les niegan lectura. Solo usan las funciones gestor_*.
create or replace function public.mi_rol()
returns text language sql stable security definer set search_path = public as $$
  select rol from public.perfiles where id = auth.uid() and activo and rol <> 'gestor'
$$;
create or replace function public._soy_gestor()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles where id = auth.uid() and activo and rol = 'gestor')
$$;
create or replace function public._mis_carteras()
returns smallint[] language sql stable security definer set search_path = public as $$
  select coalesce((select carteras from perfiles where id = auth.uid() and activo), '{}')
$$;

-- ---------- Solicitudes: cartera y quién la registró ----------
alter table public.solicitudes add column if not exists cartera_id smallint references public.carteras(id);
alter table public.solicitudes add column if not exists creado_por uuid references public.perfiles(id) default auth.uid();
create index if not exists solicitudes_cartera_idx on public.solicitudes (cartera_id);
create index if not exists solicitudes_dni_idx on public.solicitudes (regexp_replace(coalesce(dni,''), '\D', '', 'g'));

insert into public.parametros (clave, valor, descripcion)
values ('cartera_nuevas', 1, 'Cartera a la que pasan las solicitudes nuevas (1 = Cartera, 2 = Gestión Telefónica, 3 = Gestión Presencial, 4 = Gestión Telefónica #2)')
on conflict (clave) do nothing;

-- Clave del nombre igual que en Refinanciar (rfKey)
create or replace function public._rf_key(p text)
returns text language sql immutable as $$
  select coalesce(nullif(left(trim(both '-' from regexp_replace(
    lower(regexp_replace(trim(translate(coalesce(p,''), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')), '\s+', ' ', 'g')),
    '[^a-z0-9]+', '-', 'g')), 180), ''), 'sin-nombre')
$$;

-- Cartera del cliente según la última lista de préstamos cargada en Refinanciar
create or replace function public.cartera_sugerida(p_nombre text)
returns smallint language sql stable security definer set search_path = public as $$
  select c.id from (
    select p->>'cart' cart, p->>'f' f
    from refi_cortes rc, jsonb_array_elements(coalesce(rc.prestamos, '[]')) p
    where rc.id = (select max(id) from refi_cortes where jsonb_array_length(coalesce(prestamos,'[]')) > 0)
      and _rf_key(p->>'c') = _rf_key(p_nombre)
    order by p->>'f' desc nulls last limit 1
  ) x join carteras c on lower(c.nombre) = lower(trim(x.cart))
$$;

create or replace function public.tg_solicitud_cartera()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.cartera_id is null then
    if new.tipo = 'nuevo' then
      new.cartera_id := (select valor::smallint from parametros where clave = 'cartera_nuevas');
      if not exists (select 1 from carteras where id = new.cartera_id) then new.cartera_id := null; end if;
    else
      new.cartera_id := cartera_sugerida(new.nombre_cliente);
    end if;
  end if;
  if new.creado_por is null then new.creado_por := new.asesor_id; end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'solicitud_cartera' and tgrelid = 'public.solicitudes'::regclass) then
    create trigger solicitud_cartera before insert on public.solicitudes for each row execute function public.tg_solicitud_cartera();
  end if;
end $$;

-- Cambiar la cartera de una solicitud (asesor, analista, admin)
create or replace function public.asignar_cartera(p_id bigint, p_cartera smallint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not tiene_rol('asesor','analista') then raise exception 'Sin permiso'; end if;
  if p_cartera is not null and not exists (select 1 from carteras where id = p_cartera and activa) then raise exception 'Cartera no válida'; end if;
  update solicitudes set cartera_id = p_cartera where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
end $$;

-- ---------- Búsqueda del cliente por identidad ----------
create or replace function public.buscar_cliente(p_dni text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_dni text := regexp_replace(coalesce(p_dni,''), '\D', '', 'g'); u solicitudes; a solicitudes; n int; gestor boolean := _soy_gestor();
begin
  if mi_rol() is null and not gestor then raise exception 'Sin permiso'; end if;
  if length(v_dni) <> 13 then return jsonb_build_object('encontrado', false); end if;
  select count(*) into n from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni;
  if n = 0 then return jsonb_build_object('encontrado', false); end if;
  select * into u from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni order by creado_en desc limit 1;
  select * into a from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni
     and estado not in ('desembolsada','denegada','rechazada_verificacion','desistida') and not coalesce(importado,false)
   order by creado_en desc limit 1;
  return jsonb_build_object('encontrado', true, 'n', n,
    'nombre', u.nombre_cliente,
    'telefono', (select telefono from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and nullif(trim(telefono),'') is not null order by creado_en desc limit 1),
    'fecha_ingreso', (select fecha_ingreso from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and fecha_ingreso is not null order by creado_en desc limit 1),
    'ultima', jsonb_build_object('id', case when gestor then null else u.id end, 'codigo', u.codigo, 'tipo', u.tipo, 'estado', u.estado, 'fecha', u.creado_en,
       'desembolsada', (select max(desembolsado_en) from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and estado = 'desembolsada')),
    'abierta', case when a.id is null then null else jsonb_build_object('id', case when gestor then null else a.id end, 'codigo', a.codigo, 'tipo', a.tipo, 'estado', a.estado) end,
    'tiene_domicilio', u.dom_sector is not null or u.dom_lat is not null or exists (select 1 from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and (dom_sector is not null or dom_lat is not null)),
    'tiene_trabajo', exists (select 1 from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and (trab_sector is not null or trab_lat is not null)),
    'cartera_sugerida', coalesce(cartera_sugerida(u.nombre_cliente),
       (select cartera_id from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and tipo <> 'nuevo' and cartera_id is not null order by creado_en desc limit 1)));
end $$;

-- Copia a la solicitud nueva los datos del cliente de sus solicitudes anteriores (solo campos vacíos)
create or replace function public.copiar_datos_cliente(p_id bigint)
returns text[] language plpgsql security definer set search_path = public as $$
declare s solicitudes; v_dni text; c text[] := '{}'; v record;
begin
  select * into s from solicitudes where id = p_id;
  if s.id is null then raise exception 'Solicitud no encontrada'; end if;
  if not (tiene_rol('asesor','analista') or (_soy_gestor() and s.creado_por = auth.uid())) then raise exception 'Sin permiso'; end if;
  v_dni := regexp_replace(coalesce(s.dni,''), '\D', '', 'g');
  if length(v_dni) <> 13 then return c; end if;
  -- Teléfono y antigüedad
  if nullif(trim(coalesce(s.telefono,'')),'') is null then
    select telefono into v from solicitudes where id <> p_id and regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and nullif(trim(telefono),'') is not null order by creado_en desc limit 1;
    if found then update solicitudes set telefono = v.telefono where id = p_id; c := array_append(c, 'telefono'); end if;
  end if;
  if s.fecha_ingreso is null then
    select fecha_ingreso into v from solicitudes where id <> p_id and regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and fecha_ingreso is not null order by creado_en desc limit 1;
    if found then update solicitudes set fecha_ingreso = v.fecha_ingreso where id = p_id; c := array_append(c, 'fecha_ingreso'); end if;
  end if;
  -- Domicilio
  if s.dom_sector is null and s.dom_lat is null then
    select dom_lat, dom_lng, dom_sector, dom_ciudad, dom_ref into v from solicitudes
     where id <> p_id and regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and (dom_sector is not null or dom_lat is not null) order by creado_en desc limit 1;
    if found then update solicitudes set dom_lat = v.dom_lat, dom_lng = v.dom_lng, dom_sector = v.dom_sector, dom_ciudad = v.dom_ciudad, dom_ref = v.dom_ref where id = p_id; c := array_append(c, 'domicilio'); end if;
  end if;
  -- Trabajo
  if s.trab_sector is null and s.trab_lat is null then
    select trab_lat, trab_lng, trab_sector, trab_ciudad, trab_ref into v from solicitudes
     where id <> p_id and regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni and (trab_sector is not null or trab_lat is not null) order by creado_en desc limit 1;
    if found then update solicitudes set trab_lat = v.trab_lat, trab_lng = v.trab_lng, trab_sector = v.trab_sector, trab_ciudad = v.trab_ciudad, trab_ref = v.trab_ref where id = p_id; c := array_append(c, 'trabajo'); end if;
  end if;
  return c;
end $$;

-- ---------- Gestores de cobro ----------
-- Lo que ve el gestor: solicitudes de sus carteras (o que él registró), solo estatus
create or replace function public.gestor_datos()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare yo uuid := auth.uid(); mis smallint[] := _mis_carteras();
begin
  if not _soy_gestor() then raise exception 'Sin permiso'; end if;
  return jsonb_build_object(
    'carteras', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre) order by orden), '[]') from carteras where activa),
    'mias', to_jsonb(mis),
    'sols', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'codigo', s.codigo, 'nombre_cliente', s.nombre_cliente, 'dni', s.dni, 'telefono', s.telefono, 'tipo', s.tipo,
        'estado', s.estado, 'cartera_id', s.cartera_id, 'creado_en', s.creado_en, 'estado_desde', s.estado_desde,
        'desembolsado_en', s.desembolsado_en, 'en_espera', coalesce(s.en_espera, false),
        'analisis_tomado', s.analisis_tomado_en is not null,
        'creado_por', s.creado_por, 'es_mia', s.creado_por = yo,
        'registro', (select nombre from perfiles where id = s.creado_por),
        'asesor', (select nombre from perfiles where id = s.asesor_id)) order by s.creado_en desc), '[]')
      from solicitudes s
      where not coalesce(s.importado, false)
        and (s.cartera_id = any(mis) or s.creado_por = yo)
        and (s.creado_en > now() - interval '120 days' or s.estado not in ('desembolsada','denegada','rechazada_verificacion','desistida')))
  );
end $$;

-- Asesor que recibe las solicitudes de los gestores: config_app 'asesor_gestores' o el asesor activo con menos pendientes
create or replace function public._asesor_para_gestor()
returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.id from config_app c join perfiles p on p.id::text = c.valor where c.clave = 'asesor_gestores' and p.activo and p.rol in ('asesor','admin')),
    (select p.id from perfiles p where p.activo and p.rol = 'asesor'
      order by (select count(*) from solicitudes s where s.asesor_id = p.id and s.estado in ('borrador','aprobada')), p.creado_en limit 1),
    (select p.id from perfiles p where p.activo and p.rol = 'admin' order by p.creado_en limit 1))
$$;

create or replace function public.gestor_crear_solicitud(p_dni text, p_nombre text, p_tipo text, p_cartera smallint,
  p_telefono text default null, p_fecha_ingreso date default null, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_dni text := regexp_replace(coalesce(p_dni,''), '\D', '', 'g'); a solicitudes; v_cod text; c text[];
begin
  if not _soy_gestor() then raise exception 'Sin permiso'; end if;
  if p_tipo not in ('refinanciamiento','reingreso') then raise exception 'Solo puede registrar refinanciamientos o reingresos'; end if;
  if length(v_dni) <> 13 then raise exception 'Ingrese el número de identidad (13 dígitos)'; end if;
  if length(trim(coalesce(p_nombre,''))) < 3 then raise exception 'Nombre del cliente requerido'; end if;
  if p_cartera is null or not (p_cartera = any(_mis_carteras())) then raise exception 'Seleccione una de sus carteras'; end if;
  if p_fecha_ingreso is not null and p_fecha_ingreso > (now() at time zone 'America/Tegucigalpa')::date then raise exception 'La fecha de ingreso no puede ser futura'; end if;
  select * into a from solicitudes where regexp_replace(coalesce(dni,''), '\D', '', 'g') = v_dni
     and estado not in ('desembolsada','denegada','rechazada_verificacion','desistida') and not coalesce(importado,false) order by creado_en desc limit 1;
  if a.id is not null then raise exception 'Este cliente ya tiene la solicitud % en proceso', a.codigo; end if;
  insert into solicitudes (nombre_cliente, tipo, telefono, asesor_id, fecha_ingreso, dni, cartera_id, creado_por)
  values (trim(p_nombre), p_tipo, nullif(trim(coalesce(p_telefono,'')),''), _asesor_para_gestor(), p_fecha_ingreso,
          substr(v_dni,1,4) || '-' || substr(v_dni,5,4) || '-' || substr(v_dni,9,5), p_cartera, auth.uid())
  returning id, codigo into v_id, v_cod;
  perform _evento(v_id, 'creada', null, 'borrador', 'Registrada por el gestor de cobro');
  c := copiar_datos_cliente(v_id);
  if nullif(trim(coalesce(p_nota,'')),'') is not null then
    insert into comentarios (solicitud_id, autor_id, texto) values (v_id, auth.uid(), trim(p_nota));
  end if;
  return jsonb_build_object('id', v_id, 'codigo', (select codigo from solicitudes where id = v_id), 'copiados', to_jsonb(c));
end $$;

-- ---------- Administración: gestores y roles adicionales ----------
create or replace function public.configurar_gestor(p_id uuid, p_carteras smallint[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(mi_rol(),'') <> 'admin' then raise exception 'Solo admin'; end if;
  if p_id = auth.uid() then raise exception 'No puede cambiarse a sí mismo a gestor'; end if;
  if coalesce(array_length(p_carteras, 1), 0) = 0 then raise exception 'Asigne al menos una cartera al gestor'; end if;
  if exists (select 1 from unnest(p_carteras) x where not exists (select 1 from carteras where id = x)) then raise exception 'Cartera no válida'; end if;
  update perfiles set rol = 'gestor', carteras = p_carteras, roles_extra = '{}' where id = p_id;
  if not found then raise exception 'Usuario no encontrado'; end if;
end $$;

create or replace function public.fijar_roles_extra(p_id uuid, p_roles text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(mi_rol(),'') <> 'admin' then raise exception 'Solo admin'; end if;
  if exists (select 1 from unnest(coalesce(p_roles,'{}')) r where r not in ('gerente')) then raise exception 'Rol adicional no válido'; end if;
  update perfiles set roles_extra = coalesce(p_roles, '{}') where id = p_id;
  if not found then raise exception 'Usuario no encontrado'; end if;
end $$;

revoke all on function public.asignar_cartera(bigint, smallint) from public, anon;
revoke all on function public.buscar_cliente(text) from public, anon;
revoke all on function public.copiar_datos_cliente(bigint) from public, anon;
revoke all on function public.gestor_datos() from public, anon;
revoke all on function public.gestor_crear_solicitud(text, text, text, smallint, text, date, text) from public, anon;
revoke all on function public.configurar_gestor(uuid, smallint[]) from public, anon;
revoke all on function public.fijar_roles_extra(uuid, text[]) from public, anon;
revoke all on function public._asesor_para_gestor() from public, anon, authenticated;
revoke all on function public.cartera_sugerida(text) from public, anon;
grant execute on function public.cartera_sugerida(text) to authenticated;
grant execute on function public.asignar_cartera(bigint, smallint) to authenticated;
grant execute on function public.buscar_cliente(text) to authenticated;
grant execute on function public.copiar_datos_cliente(bigint) to authenticated;
grant execute on function public.gestor_datos() to authenticated;
grant execute on function public.gestor_crear_solicitud(text, text, text, smallint, text, date, text) to authenticated;
grant execute on function public.configurar_gestor(uuid, smallint[]) to authenticated;
grant execute on function public.fijar_roles_extra(uuid, text[]) to authenticated;

-- Nery Chirinos: analista con rol adicional de gerente (pedido de Somar, 21-nov-2026)
update public.perfiles set roles_extra = array['gerente'] where nombre = 'Nery Chirinos' and rol = 'analista';

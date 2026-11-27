-- Campaña "Cámbiate a nivelado" (27-nov-2026)
-- Clientes con préstamos solo interés (obsoleto) que los gestores de cobro invitan a pasarse a nivelado.
-- Aplican: préstamos con 12 meses o más desde el desembolso, o con 6 meses o más que no han abonado a capital
-- (Capital − Balance capital ≤ tolerancia), siempre que aún tengan saldo de capital. Los meses y la tolerancia se editan en Parámetros.
-- El gestor ve solo su cartera; asesor, analista, gerente y admin ven todo.

-- ---------- Parámetros ----------
insert into public.parametros (clave, valor, descripcion) values
  ('nivelado_meses_antiguedad', 12, 'Cámbiate a nivelado: meses desde el desembolso para que el préstamo aplique (aunque haya abonado a capital)'),
  ('nivelado_meses_sin_abono', 6, 'Cámbiate a nivelado: meses desde el desembolso para que aplique un préstamo que no ha abonado a capital'),
  ('nivelado_tolerancia_abono', 0, 'Cámbiate a nivelado: abono a capital (L) que todavía cuenta como "no ha abonado" (capital − balance capital)')
on conflict (clave) do nothing;

-- ---------- Tablas ----------
create table if not exists public.niv_cargas (
  id bigserial primary key,
  archivo text,
  cargado_por uuid references public.perfiles(id) default auth.uid(),
  cargado_en timestamptz not null default now(),
  filas int not null default 0,
  nuevos int not null default 0,
  salieron int not null default 0,
  omitidos int not null default 0
);

create table if not exists public.niv_prestamos (
  id bigserial primary key,
  clave text not null,
  nombre text not null,
  tipo text,
  fecha date not null,
  capital numeric not null,
  balance_capital numeric,
  balance_cuotas numeric,
  balance_mora numeric,
  balance_total numeric,
  dia_pago text,
  cartera_txt text,
  cartera_id smallint references public.carteras(id),
  en_lista boolean not null default true,
  carga_id bigint references public.niv_cargas(id),
  salio_en timestamptz,
  telefono text,
  dni text,
  resultado text check (resultado in ('no_contesta','volver_llamar','lo_pensara','acepta','no_interesa','tel_equivocado','solicitud')),
  resultado_en timestamptz,
  resultado_por uuid references public.perfiles(id),
  seguimiento_en timestamptz,
  nota text,
  monto_extra numeric,
  gestiones int not null default 0,
  solicitud_id bigint references public.solicitudes(id) on delete set null,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  unique (clave, fecha, capital)
);
create index if not exists niv_prestamos_cartera_idx on public.niv_prestamos (cartera_id);

create table if not exists public.niv_gestiones (
  id bigserial primary key,
  prestamo_id bigint not null references public.niv_prestamos(id) on delete cascade,
  autor_id uuid references public.perfiles(id) default auth.uid(),
  resultado text not null,
  nota text,
  seguimiento_en timestamptz,
  monto_extra numeric,
  solicitud_id bigint references public.solicitudes(id) on delete set null,
  creado_en timestamptz not null default now()
);
create index if not exists niv_gestiones_prestamo_idx on public.niv_gestiones (prestamo_id);

-- Sin acceso directo: todo pasa por las funciones niv_*
alter table public.niv_cargas enable row level security;
alter table public.niv_prestamos enable row level security;
alter table public.niv_gestiones enable row level security;

-- Marca de campaña en la solicitud que se genera
alter table public.solicitudes add column if not exists campana text;

-- ---------- Reglas ----------
create or replace function public._niv_meses(p_fecha date)
returns int language sql stable set search_path = public as $$
  select (extract(year from age((now() at time zone 'America/Tegucigalpa')::date, p_fecha)) * 12
        + extract(month from age((now() at time zone 'America/Tegucigalpa')::date, p_fecha)))::int
$$;

-- 'antiguedad' | 'sin_abono' | null (no aplica)
create or replace function public._niv_aplica(p_fecha date, p_capital numeric, p_balance numeric)
returns text language plpgsql stable security definer set search_path = public as $$
declare m int := _niv_meses(p_fecha);
  ma numeric := coalesce((select valor from parametros where clave = 'nivelado_meses_antiguedad'), 12);
  ms numeric := coalesce((select valor from parametros where clave = 'nivelado_meses_sin_abono'), 6);
  tol numeric := coalesce((select valor from parametros where clave = 'nivelado_tolerancia_abono'), 0);
begin
  if coalesce(p_balance, 0) < 1 then return null; end if;   -- ya no tiene saldo de capital
  if m >= ma then return 'antiguedad'; end if;
  if m >= ms and (coalesce(p_capital, 0) - coalesce(p_balance, p_capital, 0)) <= tol + 0.005 then return 'sin_abono'; end if;
  return null;
end $$;

-- Quién puede gestionar un préstamo de la campaña
create or replace function public._niv_puede(p niv_prestamos)
returns boolean language sql stable security definer set search_path = public as $$
  select tiene_rol('asesor','analista') or (_soy_gestor() and p.cartera_id = any(_mis_carteras()))
$$;

-- ---------- Datos para la pantalla ----------
create or replace function public.niv_datos()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare todos boolean := tiene_rol('asesor','analista'); mis smallint[] := '{}';
begin
  if not todos then
    if not _soy_gestor() then raise exception 'Sin permiso'; end if;
    mis := _mis_carteras();
  end if;
  return (
    with p as (
      select n.*, _niv_aplica(n.fecha, n.capital, n.balance_capital) aplica, _niv_meses(n.fecha) meses
      from niv_prestamos n
    ), v as (
      select * from p where todos or (cartera_id = any(mis) and aplica is not null and (en_lista or solicitud_id is not null))
    )
    select jsonb_build_object(
      'todos', todos,
      'carga', tiene_rol('analista'),
      'params', jsonb_build_object(
        'antig', coalesce((select valor from parametros where clave = 'nivelado_meses_antiguedad'), 12),
        'sin_abono', coalesce((select valor from parametros where clave = 'nivelado_meses_sin_abono'), 6),
        'tol', coalesce((select valor from parametros where clave = 'nivelado_tolerancia_abono'), 0)),
      'carteras', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre) order by orden), '[]') from carteras where activa),
      'mias', to_jsonb(mis),
      'ultima', (select jsonb_build_object('archivo', c.archivo, 'en', c.cargado_en, 'por', (select nombre from perfiles where id = c.cargado_por),
                   'filas', c.filas, 'nuevos', c.nuevos, 'salieron', c.salieron, 'omitidos', c.omitidos)
                 from niv_cargas c order by c.id desc limit 1),
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', v.id, 'nombre', v.nombre, 'tipo', v.tipo, 'fecha', v.fecha, 'capital', v.capital, 'bal', v.balance_capital,
          'cuotas', v.balance_cuotas, 'mora', v.balance_mora, 'total', v.balance_total, 'dia', v.dia_pago,
          'cartera_id', v.cartera_id, 'cartera_txt', v.cartera_txt, 'en_lista', v.en_lista, 'salio_en', v.salio_en,
          'telefono', v.telefono, 'dni', v.dni, 'resultado', v.resultado, 'resultado_en', v.resultado_en,
          'resultado_por', (select nombre from perfiles where id = v.resultado_por),
          'seguimiento_en', v.seguimiento_en, 'nota', v.nota, 'monto_extra', v.monto_extra, 'gestiones', v.gestiones,
          'aplica', v.aplica, 'meses', v.meses,
          'sol', (select jsonb_build_object('id', s.id, 'codigo', s.codigo, 'estado', s.estado, 'en_espera', coalesce(s.en_espera, false),
                    'analisis_tomado', s.analisis_tomado_en is not null, 'desembolsado_en', s.desembolsado_en,
                    'monto', coalesce(s.monto_aprobado, s.monto_solicitado), 'asesor', (select nombre from perfiles where id = s.asesor_id))
                  from solicitudes s where s.id = v.solicitud_id)
        ) order by v.nombre), '[]') from v),
      'gestiones', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', g.id, 'p', g.prestamo_id, 'autor_id', g.autor_id, 'autor', (select nombre from perfiles where id = g.autor_id),
          'r', g.resultado, 'nota', g.nota, 'seg', g.seguimiento_en, 'monto', g.monto_extra, 'sol', g.solicitud_id, 'en', g.creado_en
        ) order by g.creado_en desc), '[]') from niv_gestiones g where g.prestamo_id in (select id from v))
    ));
end $$;

-- ---------- Carga del listado (analista, gerente, admin) ----------
-- p_filas: [{c, t, f, cap, bal, cuo, mora, tot, dia, cart}] tal como viene la lista de préstamos del sistema.
-- Los préstamos que ya estaban conservan su gestión; los que no vienen en el archivo salen de la lista.
create or replace function public.niv_cargar(p_archivo text, p_filas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_carga bigint; v_filas int := 0; v_nuevos int := 0; v_sal int := 0; v_omit int := 0; v_apl int := 0;
begin
  if not tiene_rol('analista') then raise exception 'Solo el analista, el gerente o el administrador cargan el listado'; end if;
  if jsonb_typeof(p_filas) <> 'array' or jsonb_array_length(p_filas) = 0 then raise exception 'El archivo no trae préstamos'; end if;

  select count(*) into v_omit from jsonb_array_elements(p_filas) x where upper(coalesce(x->>'t','')) like 'NIVELADO%';
  insert into niv_cargas (archivo) values (left(p_archivo, 200)) returning id into v_carga;

  with src as (
    select distinct on (_rf_key(x->>'c'), (x->>'f')::date, round((x->>'cap')::numeric, 2))
      _rf_key(x->>'c') k, trim(x->>'c') c, nullif(trim(x->>'t'),'') t, (x->>'f')::date f, round((x->>'cap')::numeric, 2) cap,
      (x->>'bal')::numeric bal, (x->>'cuo')::numeric cuo, (x->>'mora')::numeric mora, (x->>'tot')::numeric tot,
      nullif(trim(x->>'dia'),'') dia, nullif(trim(x->>'cart'),'') cart
    from jsonb_array_elements(p_filas) x
    where nullif(trim(x->>'c'),'') is not null and (x->>'f') ~ '^\d{4}-\d{2}-\d{2}' and (x->>'cap') ~ '^-?[0-9.]+$'
      and upper(coalesce(x->>'t','')) not like 'NIVELADO%'
    order by 1, 4, 5
  ), up as (
    insert into niv_prestamos as n (clave, nombre, tipo, fecha, capital, balance_capital, balance_cuotas, balance_mora, balance_total,
                                    dia_pago, cartera_txt, cartera_id, en_lista, carga_id, salio_en, actualizado_en)
    select k, c, t, f, cap, bal, cuo, mora, tot, dia, cart,
           (select id from carteras where lower(nombre) = lower(cart) limit 1), true, v_carga, null, now()
    from src
    on conflict (clave, fecha, capital) do update set
      nombre = excluded.nombre, tipo = excluded.tipo, balance_capital = excluded.balance_capital, balance_cuotas = excluded.balance_cuotas,
      balance_mora = excluded.balance_mora, balance_total = excluded.balance_total, dia_pago = excluded.dia_pago,
      cartera_txt = excluded.cartera_txt, cartera_id = coalesce(excluded.cartera_id, n.cartera_id),
      en_lista = true, carga_id = excluded.carga_id, salio_en = null, actualizado_en = now()
    returning (xmax = 0) nuevo
  )
  select count(*), count(*) filter (where nuevo) into v_filas, v_nuevos from up;

  if v_filas = 0 then raise exception 'No se reconoció ningún préstamo solo interés en el archivo'; end if;

  update niv_prestamos set en_lista = false, salio_en = now(), actualizado_en = now()
   where en_lista and carga_id is distinct from v_carga;
  get diagnostics v_sal = row_count;

  -- Teléfono e identidad del cliente según sus solicitudes en VerifyCredit (por nombre)
  update niv_prestamos n set telefono = x.telefono from (
    select distinct on (_rf_key(nombre_cliente)) _rf_key(nombre_cliente) k, telefono from solicitudes
     where nullif(trim(coalesce(telefono,'')),'') is not null order by _rf_key(nombre_cliente), creado_en desc) x
   where x.k = n.clave and nullif(trim(coalesce(n.telefono,'')),'') is null;
  update niv_prestamos n set dni = x.dni from (
    select distinct on (_rf_key(nombre_cliente)) _rf_key(nombre_cliente) k, dni from solicitudes
     where length(regexp_replace(coalesce(dni,''), '\D', '', 'g')) = 13 order by _rf_key(nombre_cliente), creado_en desc) x
   where x.k = n.clave and n.dni is null;

  select count(*) into v_apl from niv_prestamos where en_lista and _niv_aplica(fecha, capital, balance_capital) is not null;
  update niv_cargas set filas = v_filas, nuevos = v_nuevos, salieron = v_sal, omitidos = v_omit where id = v_carga;
  return jsonb_build_object('carga', v_carga, 'filas', v_filas, 'nuevos', v_nuevos, 'actualizados', v_filas - v_nuevos,
                            'salieron', v_sal, 'omitidos', v_omit, 'aplican', v_apl);
end $$;

-- ---------- Registrar la respuesta del cliente ----------
create or replace function public.niv_gestionar(p_id bigint, p_resultado text, p_nota text default null,
  p_seguimiento timestamptz default null, p_monto_extra numeric default null, p_telefono text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p niv_prestamos; s solicitudes; v_nota text := nullif(trim(coalesce(p_nota,'')),'');
begin
  select * into p from niv_prestamos where id = p_id for update;
  if p.id is null then raise exception 'Préstamo no encontrado'; end if;
  if not _niv_puede(p) then raise exception 'Este cliente no es de su cartera'; end if;
  if p_resultado not in ('no_contesta','volver_llamar','lo_pensara','acepta','no_interesa','tel_equivocado') then raise exception 'Respuesta no válida'; end if;
  if p_resultado = 'volver_llamar' and p_seguimiento is null then raise exception 'Indique cuándo volver a llamar'; end if;
  if p_resultado = 'no_interesa' and v_nota is null then raise exception 'Escriba el motivo por el que no le interesa'; end if;
  if p_seguimiento is not null and p_seguimiento < now() - interval '10 minutes' then raise exception 'La fecha para volver a llamar ya pasó'; end if;
  if p_monto_extra is not null and p_monto_extra < 0 then raise exception 'Monto extra no válido'; end if;
  if p.solicitud_id is not null then
    select * into s from solicitudes where id = p.solicitud_id;
    if s.id is not null and s.estado not in ('denegada','rechazada_verificacion','desistida') then
      raise exception 'Ya tiene la solicitud % (%). Siga su avance en Mi cartera.', s.codigo, s.estado;
    end if;
  end if;
  insert into niv_gestiones (prestamo_id, resultado, nota, seguimiento_en, monto_extra)
  values (p.id, p_resultado, v_nota, p_seguimiento, case when p_resultado = 'acepta' then p_monto_extra end);
  update niv_prestamos set resultado = p_resultado, resultado_en = now(), resultado_por = auth.uid(),
    seguimiento_en = case when p_resultado in ('acepta','no_interesa') then null else p_seguimiento end,
    nota = v_nota, monto_extra = case when p_resultado = 'acepta' then p_monto_extra else monto_extra end,
    gestiones = gestiones + 1,
    telefono = coalesce(nullif(trim(coalesce(p_telefono,'')),''), telefono), actualizado_en = now()
  where id = p.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.niv_telefono(p_id bigint, p_telefono text)
returns void language plpgsql security definer set search_path = public as $$
declare p niv_prestamos;
begin
  select * into p from niv_prestamos where id = p_id;
  if p.id is null then raise exception 'Préstamo no encontrado'; end if;
  if not _niv_puede(p) then raise exception 'Este cliente no es de su cartera'; end if;
  update niv_prestamos set telefono = nullif(trim(coalesce(p_telefono,'')),''), actualizado_en = now() where id = p_id;
end $$;

-- ---------- Solicitud de cambio de modalidad ----------
-- Llega al asesor (como las de los gestores) para revisarla y enviarla a análisis. Tipo cambio_modalidad, plan nivelado.
create or replace function public.niv_crear_solicitud(p_id bigint, p_dni text, p_telefono text default null,
  p_monto_extra numeric default null, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p niv_prestamos; s solicitudes; a solicitudes; v_dni text := regexp_replace(coalesce(p_dni,''), '\D', '', 'g');
  v_id bigint; v_cod text; v_asesor uuid; v_tp text; v_txt text; c text[];
begin
  select * into p from niv_prestamos where id = p_id for update;
  if p.id is null then raise exception 'Préstamo no encontrado'; end if;
  if not _niv_puede(p) then raise exception 'Este cliente no es de su cartera'; end if;
  if length(v_dni) <> 13 then raise exception 'Ingrese el número de identidad (13 dígitos)'; end if;
  if p_monto_extra is not null and p_monto_extra < 0 then raise exception 'Monto extra no válido'; end if;
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
  v_tp := case when upper(coalesce(p.tipo,'')) like '%SEMANAL%' then 'Semanal' when upper(coalesce(p.tipo,'')) like '%MENSUAL%' then 'Mensual' else 'Quincenal' end;

  insert into solicitudes (nombre_cliente, tipo, telefono, asesor_id, dni, cartera_id, creado_por, plan_pago, tipo_pago,
                           saldo_capital, monto_solicitado, campana)
  values (p.nombre, 'cambio_modalidad', coalesce(nullif(trim(coalesce(p_telefono,'')),''), p.telefono), v_asesor,
          substr(v_dni,1,4) || '-' || substr(v_dni,5,4) || '-' || substr(v_dni,9,5), p.cartera_id, auth.uid(), 'nivelado', v_tp,
          p.balance_capital, round(coalesce(p.balance_capital, 0) + coalesce(p_monto_extra, 0)), 'nivelado')
  returning id, codigo into v_id, v_cod;
  perform _evento(v_id, 'creada', null, 'borrador', 'Campaña Cámbiate a nivelado');
  c := copiar_datos_cliente(v_id);

  v_txt := 'Campaña Cámbiate a nivelado. Préstamo solo interés del ' || to_char(p.fecha, 'DD/MM/YYYY')
    || ' por L ' || to_char(p.capital, 'FM999,999,990') || ', saldo de capital L ' || to_char(coalesce(p.balance_capital,0), 'FM999,999,990.00')
    || coalesce(', ' || p.tipo, '') || coalesce(', ' || p.dia_pago, '') || '.'
    || case when coalesce(p_monto_extra, 0) > 0 then ' El cliente quiere L ' || to_char(p_monto_extra, 'FM999,999,990') || ' adicionales.' else ' Sin monto adicional.' end
    || coalesce(' ' || nullif(trim(coalesce(p_nota,'')),''), '');
  insert into comentarios (solicitud_id, autor_id, texto) values (v_id, auth.uid(), v_txt);

  insert into niv_gestiones (prestamo_id, resultado, nota, monto_extra, solicitud_id)
  values (p.id, 'solicitud', nullif(trim(coalesce(p_nota,'')),''), p_monto_extra, v_id);
  update niv_prestamos set solicitud_id = v_id, resultado = 'solicitud', resultado_en = now(), resultado_por = auth.uid(),
    seguimiento_en = null, monto_extra = p_monto_extra, gestiones = gestiones + 1,
    dni = substr(v_dni,1,4) || '-' || substr(v_dni,5,4) || '-' || substr(v_dni,9,5),
    telefono = coalesce(nullif(trim(coalesce(p_telefono,'')),''), telefono), actualizado_en = now()
  where id = p.id;
  return jsonb_build_object('id', v_id, 'codigo', (select codigo from solicitudes where id = v_id), 'copiados', to_jsonb(c));
end $$;

-- ---------- Permisos ----------
revoke all on function public._niv_meses(date) from public, anon;
revoke all on function public._niv_aplica(date, numeric, numeric) from public, anon;
revoke all on function public._niv_puede(niv_prestamos) from public, anon, authenticated;
revoke all on function public.niv_datos() from public, anon;
revoke all on function public.niv_cargar(text, jsonb) from public, anon;
revoke all on function public.niv_gestionar(bigint, text, text, timestamptz, numeric, text) from public, anon;
revoke all on function public.niv_telefono(bigint, text) from public, anon;
revoke all on function public.niv_crear_solicitud(bigint, text, text, numeric, text) from public, anon;
grant execute on function public._niv_meses(date) to authenticated;
grant execute on function public._niv_aplica(date, numeric, numeric) to authenticated;
grant execute on function public.niv_datos() to authenticated;
grant execute on function public.niv_cargar(text, jsonb) to authenticated;
grant execute on function public.niv_gestionar(bigint, text, text, timestamptz, numeric, text) to authenticated;
grant execute on function public.niv_telefono(bigint, text) to authenticated;
grant execute on function public.niv_crear_solicitud(bigint, text, text, numeric, text) to authenticated;

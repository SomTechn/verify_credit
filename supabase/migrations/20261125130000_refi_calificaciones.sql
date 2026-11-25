-- Refinanciar: historial de calificaciones del analista (Aplica / No aplica / Sin definir)
-- y regla de 15 días: un cliente marcado "Aplica" no puede volver a marcarse "Aplica" hasta pasados
-- refi_dias_reaplica días (para no saturarlo de mensajes). El mismo día sí se puede corregir.

insert into public.parametros (clave, valor) values ('refi_dias_reaplica', '15')
  on conflict (clave) do nothing;

alter table public.refi_clientes add column if not exists aplica_si_en timestamptz;   -- última vez que se marcó "Aplica" (no se borra al reiniciar)

create table if not exists public.refi_calificaciones (
  id bigserial primary key,
  clave text not null,
  nombre text,
  aplica text,                 -- 'si' | 'no' | null (sin definir)
  limite numeric,
  nivel integer,
  comentario text,
  fecha_corte date,
  por uuid,
  en timestamptz not null default now(),
  nota text
);
create index if not exists refi_calif_clave on public.refi_calificaciones (clave, en desc);
create index if not exists refi_calif_en on public.refi_calificaciones (en desc);
alter table public.refi_calificaciones enable row level security;
drop policy if exists refi_calif_sel on public.refi_calificaciones;
create policy refi_calif_sel on public.refi_calificaciones for select to authenticated using ((select public.mi_rol()) is not null);
revoke insert, update, delete on public.refi_calificaciones from authenticated, anon;
grant select on public.refi_calificaciones to authenticated;

create or replace function public.refi_clientes_guard()
 returns trigger language plpgsql set search_path to 'public' as $function$
declare
  r text := mi_rol();
  v_dias int; v_hoy date := (now() at time zone 'America/Tegucigalpa')::date; v_desde timestamptz;
begin
  -- La fecha de la última marca "Aplica" solo la pone este trigger (los usuarios no pueden cambiarla)
  if auth.uid() is not null then
    if tg_op = 'UPDATE' then new.aplica_si_en := old.aplica_si_en; else new.aplica_si_en := null; end if;
  end if;
  if new.aplica = 'si' and (tg_op = 'INSERT' or old.aplica is distinct from 'si') then
    if auth.uid() is not null and tg_op = 'UPDATE' and old.aplica_si_en is not null
       and (old.aplica_si_en at time zone 'America/Tegucigalpa')::date <> v_hoy then
      select coalesce(valor::int, 15) into v_dias from parametros where clave = 'refi_dias_reaplica';
      v_desde := old.aplica_si_en + make_interval(days => coalesce(v_dias, 15));
      if now() < v_desde then
        raise exception 'Este cliente se marcó "Aplica" el %. Para no saturarlo de mensajes podrá volver a marcarse "Aplica" desde el %.',
          to_char(old.aplica_si_en at time zone 'America/Tegucigalpa', 'DD/MM/YYYY'), to_char(v_desde at time zone 'America/Tegucigalpa', 'DD/MM/YYYY');
      end if;
    end if;
    -- Corrección el mismo día: se conserva la hora original
    if tg_op = 'INSERT' or old.aplica_si_en is null or (old.aplica_si_en at time zone 'America/Tegucigalpa')::date <> v_hoy then
      new.aplica_si_en := now();
    end if;
  end if;

  if auth.uid() is null then return new; end if;
  if r is null then raise exception 'Sin permiso'; end if;
  if r = 'asesor' then
    if tg_op = 'INSERT' and (new.limite is not null or new.aplica is not null or new.nivel is not null or new.bloqueado) then
      raise exception 'Solo el analista puede asignar el límite, su nivel, decidir si aplica o bloquear al cliente';
    end if;
    if tg_op = 'UPDATE' and (new.limite is distinct from old.limite or new.aplica is distinct from old.aplica or new.nivel is distinct from old.nivel
        or new.bloqueado is distinct from old.bloqueado or new.motivo_bloqueo is distinct from old.motivo_bloqueo) then
      raise exception 'Solo el analista puede asignar el límite, su nivel, decidir si aplica o bloquear al cliente';
    end if;
  end if;
  if new.bloqueado and (tg_op = 'INSERT' or not old.bloqueado) then
    new.bloqueado_en := now(); new.bloqueado_por := auth.uid();
  elsif not new.bloqueado then
    new.bloqueado_en := null; new.bloqueado_por := null;
  else
    new.bloqueado_en := old.bloqueado_en; new.bloqueado_por := old.bloqueado_por;
  end if;
  new.actualizado_por := auth.uid();
  new.actualizado_en := now();
  return new;
end $function$;

-- Cada vez que el analista cambia "¿Aplica?" queda una fila en el historial (el reinicio por corte nuevo no se registra aquí)
create or replace function public.refi_calificacion_log()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if coalesce(current_setting('vc.refi_reinicio', true), '') = '1' then return null; end if;
  if tg_op = 'INSERT' and new.aplica is null then return null; end if;
  if tg_op = 'UPDATE' and new.aplica is not distinct from old.aplica then return null; end if;
  insert into refi_calificaciones (clave, nombre, aplica, limite, nivel, comentario, fecha_corte, por)
  values (new.clave, new.nombre, new.aplica, new.limite, new.nivel, new.comentario,
          (select fecha_corte from refi_cortes order by id desc limit 1), coalesce(auth.uid(), new.actualizado_por));
  return null;
end $function$;
drop trigger if exists refi_calificacion_log on public.refi_clientes;
create trigger refi_calificacion_log after insert or update of aplica on public.refi_clientes
  for each row execute function public.refi_calificacion_log();

-- El reinicio por corte nuevo no es una calificación: se marca para que el trigger no lo registre
create or replace function public.refi_reiniciar_marcas(p_corte bigint default null::bigint)
 returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  v_n integer;
  v_corte date;
  v_hoy date := (now() at time zone 'America/Tegucigalpa')::date;
begin
  if coalesce(public.mi_rol(), '') not in ('analista', 'admin') then
    raise exception 'Solo el analista puede reiniciar las marcas de refinanciamiento';
  end if;
  if p_corte is not null then
    select fecha_corte into v_corte from public.refi_cortes where id = p_corte;
  end if;
  perform set_config('vc.refi_reinicio', '1', true);

  with nuevos as (
    select c.clave,
      (case when jsonb_typeof(c.historial) = 'array' then c.historial else '[]'::jsonb end)
        || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
             'reinicio', v_hoy, 'corte_nuevo', v_corte, 'aplica', c.aplica,
             'contactado', nullif(c.contactado, false), 'fecha_contacto', c.fecha_contacto,
             'monto', c.monto_colocado, 'fecha', c.fecha_colocado))) as h
    from public.refi_clientes c
    where c.aplica is not null or c.contactado or c.colocado
  )
  update public.refi_clientes c set
    historial = (select coalesce(jsonb_agg(e order by i), '[]'::jsonb)
                 from jsonb_array_elements(n.h) with ordinality t(e, i)
                 where i > jsonb_array_length(n.h) - 20),
    aplica = null, contactado = false, fecha_contacto = null,
    colocado = false, monto_colocado = null, fecha_colocado = null,
    actualizado_por = auth.uid(), actualizado_en = now()
  from nuevos n
  where c.clave = n.clave;

  get diagnostics v_n = row_count;
  perform set_config('vc.refi_reinicio', '', true);
  return v_n;
end;
$function$;

-- Datos que ya existían: las marcas actuales entran al historial con la fecha de su última actualización,
-- y los "Aplica" actuales empiezan a contar los 15 días desde esa fecha.
update public.refi_clientes set aplica_si_en = actualizado_en where aplica = 'si' and aplica_si_en is null;
insert into public.refi_calificaciones (clave, nombre, aplica, limite, nivel, comentario, fecha_corte, por, en, nota)
select clave, nombre, aplica, limite, nivel, comentario, null, actualizado_por, actualizado_en, 'Registrada antes de activar el historial'
from public.refi_clientes where aplica is not null
  and not exists (select 1 from public.refi_calificaciones x where x.clave = refi_clientes.clave);
-- Calificaciones del corte anterior que se borraron al reiniciar el 19-nov (sin hora exacta)
insert into public.refi_calificaciones (clave, nombre, aplica, fecha_corte, en, nota)
select c.clave, c.nombre, e->>'aplica', null, ((e->>'reinicio')::date + time '08:00') at time zone 'America/Tegucigalpa',
  'Calificación del corte anterior (fecha exacta no registrada; se borró al cargar el corte del ' || to_char((e->>'reinicio')::date, 'DD/MM/YYYY') || ')'
from public.refi_clientes c, jsonb_array_elements(case when jsonb_typeof(c.historial) = 'array' then c.historial else '[]'::jsonb end) e
where e ? 'reinicio' and e->>'aplica' in ('si', 'no');

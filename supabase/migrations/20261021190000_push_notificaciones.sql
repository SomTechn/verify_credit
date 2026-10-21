-- Notificaciones push (escritorio y teléfono) aunque la app esté cerrada.
-- Un trigger avisa a la Edge Function "push" cuando una solicitud entra o cambia de estado, o cuando hay un comentario;
-- la función decide a quién avisar y envía el push a los dispositivos suscritos.
create extension if not exists pg_net with schema extensions;
create schema if not exists private;

-- Claves VAPID y secreto compartido trigger → función (no expuestos por la API)
create table if not exists private.push_config (k text primary key, v text not null);
insert into private.push_config (k, v) values ('secreto', encode(extensions.gen_random_bytes(24), 'hex')) on conflict (k) do nothing;

-- Dispositivos suscritos (un endpoint por navegador/teléfono)
create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  agente text,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
alter table public.push_subs enable row level security;   -- sin políticas: solo vía las funciones de abajo
create index if not exists push_subs_user on public.push_subs(user_id);

create or replace function public.guardar_push(p_endpoint text, p_p256dh text, p_auth text, p_agente text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is null then raise exception 'Sin permiso'; end if;
  insert into push_subs (endpoint, user_id, p256dh, auth, agente) values (p_endpoint, auth.uid(), p_p256dh, p_auth, p_agente)
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth, agente = excluded.agente, actualizado_en = now();
end $$;
create or replace function public.borrar_push(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;
revoke all on function public.guardar_push(text, text, text, text), public.borrar_push(text) from public, anon;
grant execute on function public.guardar_push(text, text, text, text), public.borrar_push(text) to authenticated;

-- Solo para la Edge Function (service_role)
create or replace function public.push_config_get() returns jsonb
language sql security definer set search_path = private as $$
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from private.push_config;
$$;
create or replace function public.push_config_init(p_publica text, p_privada text) returns jsonb
language plpgsql security definer set search_path = private as $$
begin
  insert into private.push_config (k, v) values ('publica', p_publica), ('privada', p_privada) on conflict (k) do nothing;
  return (select jsonb_object_agg(k, v) from private.push_config);
end $$;
revoke all on function public.push_config_get(), public.push_config_init(text, text) from public, anon, authenticated;
grant execute on function public.push_config_get(), public.push_config_init(text, text) to service_role;

-- Trigger: envía el evento a la función
create or replace function private.push_evento() returns trigger
language plpgsql security definer set search_path = public as $$
declare sec text; ev jsonb;
begin
  if tg_table_name = 'solicitudes' then
    if coalesce(new.importado, false) then return null; end if;
    if tg_op = 'UPDATE' and new.estado is not distinct from old.estado then return null; end if;
    if tg_op = 'INSERT' and new.estado = 'borrador' then return null; end if;
    ev := jsonb_build_object('tabla', 'solicitudes', 'id', new.id, 'codigo', new.codigo, 'tipo', new.tipo, 'estado', new.estado,
      'antes', case when tg_op = 'UPDATE' then old.estado end, 'cliente', new.nombre_cliente,
      'asesor', new.asesor_id, 'analista', new.analista_id, 'verificador', new.verificador_id);
  else
    ev := jsonb_build_object('tabla', 'comentarios', 'solicitud', new.solicitud_id, 'autor', new.autor_id, 'texto', left(new.texto, 140));
  end if;
  select v into sec from private.push_config where k = 'secreto';
  perform net.http_post(
    url := 'https://edmvfqelxsxevpmxgbav.supabase.co/functions/v1/push',
    body := ev || jsonb_build_object('actor', auth.uid()),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-vc-secreto', sec),
    timeout_milliseconds := 10000);
  return null;
exception when others then
  return null;   -- un fallo al avisar nunca debe impedir guardar la solicitud
end $$;

drop trigger if exists push_solicitudes on public.solicitudes;
create trigger push_solicitudes after insert or update of estado on public.solicitudes
  for each row execute function private.push_evento();
drop trigger if exists push_comentarios on public.comentarios;
create trigger push_comentarios after insert on public.comentarios
  for each row execute function private.push_evento();

-- CRM WhatsApp, fase 2: conversaciones, mensajes, fotos y permiso de acceso.
-- Acceso: solo los usuarios con perfiles.ver_whatsapp = true (lo concede el administrador).
-- El administrador NO lo tiene por defecto: también necesita el permiso (se le activa abajo).

-- 1) Permiso por usuario
alter table public.perfiles add column if not exists ver_whatsapp boolean not null default false;

create or replace function public.puede_ver_whatsapp()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select ver_whatsapp from perfiles where id = auth.uid()), false)
$$;
revoke all on function public.puede_ver_whatsapp() from public;
grant execute on function public.puede_ver_whatsapp() to authenticated;

create or replace function public.fijar_ver_whatsapp(p_id uuid, p_valor boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador puede dar este permiso'; end if;
  update perfiles set ver_whatsapp = coalesce(p_valor, false) where id = p_id;
end $$;
revoke all on function public.fijar_ver_whatsapp(uuid, boolean) from public;
grant execute on function public.fijar_ver_whatsapp(uuid, boolean) to authenticated;

-- Al crear esto, solo el administrador actual queda con acceso
update public.perfiles set ver_whatsapp = true where rol = 'admin';

-- 2) Conversaciones (una por número de cliente) y mensajes
create table if not exists public.wa_conversaciones (
  telefono text primary key,               -- solo dígitos, con código de país (50432032345)
  nombre text,                             -- nombre de perfil de WhatsApp
  ultimo_texto text,
  ultimo_autor text,                       -- cliente | bot | asesor
  ultimo_en timestamptz,
  no_leidos integer not null default 0,
  creado_en timestamptz not null default now()
);

create table if not exists public.wa_mensajes (
  id bigint generated always as identity primary key,
  telefono text not null references public.wa_conversaciones(telefono) on delete cascade,
  wamid text unique,                       -- id de WhatsApp (mensajes entrantes)
  autor text not null check (autor in ('cliente', 'bot', 'asesor')),
  tipo text not null default 'text',       -- text | image | document | audio | video | sticker | otro
  texto text,
  media_path text,                         -- ruta en el bucket privado wa-media
  media_mime text,
  media_estado text,                       -- pendiente | guardada | error | no_disponible
  enviado_en timestamptz not null default now(),
  evento_id bigint references public.wa_eventos(id) on delete set null,
  creado_en timestamptz not null default now()
);
create index if not exists wa_mensajes_tel_fecha on public.wa_mensajes (telefono, enviado_en);
create index if not exists wa_conversaciones_ultimo on public.wa_conversaciones (ultimo_en desc);

alter table public.wa_conversaciones enable row level security;
alter table public.wa_mensajes enable row level security;

drop policy if exists wa_conv_leer on public.wa_conversaciones;
create policy wa_conv_leer on public.wa_conversaciones for select to authenticated using (public.puede_ver_whatsapp());
drop policy if exists wa_msj_leer on public.wa_mensajes;
create policy wa_msj_leer on public.wa_mensajes for select to authenticated using (public.puede_ver_whatsapp());

-- Marcar como leída (único cambio que la app hace)
create or replace function public.wa_marcar_leida(p_tel text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not puede_ver_whatsapp() then raise exception 'Sin acceso a WhatsApp'; end if;
  update wa_conversaciones set no_leidos = 0 where telefono = p_tel;
end $$;
revoke all on function public.wa_marcar_leida(text) from public;
grant execute on function public.wa_marcar_leida(text) to authenticated;

-- 3) Guardar un mensaje y actualizar su conversación (lo llama la función wa-webhook con service_role)
create or replace function public.wa_guardar_mensaje(
  p_tel text, p_nombre text, p_wamid text, p_autor text, p_tipo text, p_texto text,
  p_media_estado text, p_enviado_en timestamptz, p_evento_id bigint
) returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_resumen text;
begin
  v_resumen := coalesce(nullif(p_texto, ''), case p_tipo when 'image' then 'Foto' when 'document' then 'Documento'
                 when 'audio' then 'Audio' when 'video' then 'Video' when 'sticker' then 'Sticker' else 'Mensaje' end);
  insert into wa_conversaciones (telefono, nombre, ultimo_texto, ultimo_autor, ultimo_en, no_leidos)
  values (p_tel, nullif(p_nombre, ''), v_resumen, p_autor, p_enviado_en, case when p_autor = 'cliente' then 1 else 0 end)
  on conflict (telefono) do update set
    nombre = coalesce(nullif(excluded.nombre, ''), wa_conversaciones.nombre),
    ultimo_texto = case when excluded.ultimo_en >= coalesce(wa_conversaciones.ultimo_en, '-infinity') then excluded.ultimo_texto else wa_conversaciones.ultimo_texto end,
    ultimo_autor = case when excluded.ultimo_en >= coalesce(wa_conversaciones.ultimo_en, '-infinity') then excluded.ultimo_autor else wa_conversaciones.ultimo_autor end,
    ultimo_en = greatest(excluded.ultimo_en, wa_conversaciones.ultimo_en),
    no_leidos = case when p_autor = 'cliente' then wa_conversaciones.no_leidos + 1
                     when p_autor = 'asesor' then 0 else wa_conversaciones.no_leidos end;
  insert into wa_mensajes (telefono, wamid, autor, tipo, texto, media_estado, enviado_en, evento_id)
  values (p_tel, nullif(p_wamid, ''), p_autor, coalesce(p_tipo, 'text'), nullif(p_texto, ''), p_media_estado, p_enviado_en, p_evento_id)
  on conflict (wamid) do nothing
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.wa_guardar_mensaje(text, text, text, text, text, text, text, timestamptz, bigint) from public, anon, authenticated;

-- 4) Tiempo real para la bandeja
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'wa_conversaciones') then
    alter publication supabase_realtime add table public.wa_conversaciones;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'wa_mensajes') then
    alter publication supabase_realtime add table public.wa_mensajes;
  end if;
end $$;

-- 5) Fotos: bucket privado; solo quien tiene el permiso puede verlas (la subida la hace el servidor)
insert into storage.buckets (id, name, public) values ('wa-media', 'wa-media', false)
on conflict (id) do nothing;
drop policy if exists wa_media_leer on storage.objects;
create policy wa_media_leer on storage.objects for select to authenticated
  using (bucket_id = 'wa-media' and public.puede_ver_whatsapp());

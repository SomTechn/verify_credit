-- Nombre con el que cada verificador se presenta en los mensajes de WhatsApp ({verificador}). Lo asigna el admin.
alter table public.perfiles add column if not exists nombre_wa text;

create or replace function public.guardar_nombre_wa(p_usuario uuid, p_nombre text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador asigna este nombre'; end if;
  update perfiles set nombre_wa = nullif(trim(p_nombre), '') where id = p_usuario;
  if not found then raise exception 'Usuario no encontrado'; end if;
end $$;
revoke all on function public.guardar_nombre_wa(uuid, text) from public, anon;
grant execute on function public.guardar_nombre_wa(uuid, text) to authenticated;

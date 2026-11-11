-- Notificaciones por persona: 'rol' = las que le tocan por su rol; 'transferencias' = solo los desembolsos por transferencia por confirmar (gerente)
alter table public.perfiles add column if not exists avisos text not null default 'rol';
alter table public.perfiles drop constraint if exists perfiles_avisos_check;
alter table public.perfiles add constraint perfiles_avisos_check check (avisos in ('rol','transferencias'));

create or replace function public.fijar_avisos(p_id uuid, p_avisos text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if mi_rol() is distinct from 'admin' then raise exception 'Sin permiso'; end if;
  if p_avisos not in ('rol','transferencias') then raise exception 'Opción no válida'; end if;
  update perfiles set avisos = p_avisos where id = p_id;
  if not found then raise exception 'Usuario no encontrado'; end if;
end $$;
revoke all on function public.fijar_avisos(uuid, text) from public, anon;
grant execute on function public.fijar_avisos(uuid, text) to authenticated, service_role;

-- El administrador ve quién tiene las notificaciones activadas (cantidad de dispositivos y última vez)
create or replace function public.push_estado_usuarios()
returns table (user_id uuid, dispositivos integer, ultimo timestamptz)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if mi_rol()::text is distinct from 'admin' then raise exception 'Sin permiso'; end if;
  return query select s.user_id, count(*)::int, max(coalesce(s.actualizado_en, s.creado_en)) from push_subs s group by s.user_id;
end $$;
revoke all on function public.push_estado_usuarios() from public, anon;
grant execute on function public.push_estado_usuarios() to authenticated, service_role;

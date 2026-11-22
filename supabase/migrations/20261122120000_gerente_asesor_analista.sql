-- El gerente (rol adicional) tiene los permisos de asesor y de analista.
create or replace function public.tiene_rol(variadic roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select rol = any(roles) or rol = 'admin'
                     or ('gerente' = any(roles_extra) and rol <> 'gestor' and roles && array['asesor','analista'])
                   from public.perfiles where id = auth.uid() and activo), false)
$$;

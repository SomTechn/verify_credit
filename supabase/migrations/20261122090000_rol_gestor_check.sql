-- Rol "gestor" (gestor de cobro): se agrega a los roles permitidos de perfiles.
alter table public.perfiles drop constraint if exists perfiles_rol_check;
alter table public.perfiles add constraint perfiles_rol_check
  check (rol = any (array['asesor','analista','verificador','admin','cajero','solicitante','gestor']));

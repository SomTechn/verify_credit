-- "Cartera" no es una cartera: solo Gestión Telefónica, Gestión Telefónica #2 y Gestión Presencial.
set session_replication_role = replica;
update public.solicitudes set cartera_id = null where cartera_id = 1;
reset session_replication_role;
update public.perfiles set carteras = array_remove(carteras, 1::smallint) where 1::smallint = any(carteras);
delete from public.carteras where id = 1;
update public.parametros set valor = 0,
  descripcion = 'Cartera de las solicitudes nuevas (0 = sin cartera, 2 = Gestión Telefónica, 3 = Gestión Presencial, 4 = Gestión Telefónica #2)'
where clave = 'cartera_nuevas';

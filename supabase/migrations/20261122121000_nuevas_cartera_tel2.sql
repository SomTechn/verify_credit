-- Solicitudes nuevas sin cartera → Gestión Telefónica #2 (predeterminada elegida por Somar el 21-nov)
set session_replication_role = replica;
update public.solicitudes set cartera_id = 4 where tipo = 'nuevo' and cartera_id is null;
reset session_replication_role;

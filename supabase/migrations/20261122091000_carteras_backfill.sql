-- Datos existentes: quién la registró = asesor; cartera de nuevas = la predeterminada;
-- refinanciamientos/reingresos = la del cliente en la última lista de préstamos.
-- Sin disparar los triggers de actualización (no cambia actualizado_en ni estados).
set session_replication_role = replica;
update public.solicitudes set creado_por = asesor_id where creado_por is null;
update public.solicitudes set cartera_id = 1 where cartera_id is null and tipo = 'nuevo';
with lista as (
  select distinct on (_rf_key(p->>'c')) _rf_key(p->>'c') k, p->>'cart' cart
  from refi_cortes rc, jsonb_array_elements(coalesce(rc.prestamos, '[]')) p
  where rc.id = (select max(id) from refi_cortes where jsonb_array_length(coalesce(prestamos,'[]')) > 0)
  order by _rf_key(p->>'c'), p->>'f' desc nulls last
)
update public.solicitudes s set cartera_id = c.id
from lista l join public.carteras c on lower(c.nombre) = lower(trim(l.cart))
where s.cartera_id is null and s.tipo <> 'nuevo' and _rf_key(s.nombre_cliente) = l.k;
reset session_replication_role;

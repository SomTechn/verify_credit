-- Avisos push de verificación: solo al verificador asignado.
-- Antes: si la solicitud pasaba a "por verificar" sin verificador, el aviso llegaba a TODOS los verificadores,
-- y al asignarlo después en Por verificar no llegaba ningún aviso.
-- Ahora: el cambio de estado lleva también verificador_trabajo, y asignar/cambiar el verificador (domicilio o
-- trabajo) de una solicitud por verificar envía el evento 'asignacion' solo a los recién asignados.
create or replace function private.push_evento()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare sec text; ev jsonb; nuevos jsonb := '[]'::jsonb;
begin
  if tg_table_name = 'solicitudes' then
    if coalesce(new.importado, false) then return null; end if;
    if tg_op = 'INSERT' and new.estado = 'borrador' then return null; end if;
    if tg_op = 'UPDATE' and new.estado is not distinct from old.estado then
      -- Mismo estado: solo interesa la asignación de verificador en solicitudes por verificar
      if new.estado <> 'por_verificar' then return null; end if;
      if new.verificador_id is not null and new.verificador_id is distinct from old.verificador_id then
        nuevos := nuevos || jsonb_build_array(jsonb_build_object('id', new.verificador_id,
          'lugar', case when new.verificador_trabajo_id is not null and new.verificador_trabajo_id <> new.verificador_id then 'Domicilio' else '' end));
      end if;
      if new.verificador_trabajo_id is not null and new.verificador_trabajo_id is distinct from old.verificador_trabajo_id
         and new.verificador_trabajo_id is distinct from new.verificador_id then
        nuevos := nuevos || jsonb_build_array(jsonb_build_object('id', new.verificador_trabajo_id, 'lugar', 'Trabajo'));
      end if;
      if jsonb_array_length(nuevos) = 0 then return null; end if;
      ev := jsonb_build_object('tabla', 'asignacion', 'id', new.id, 'codigo', new.codigo, 'tipo', new.tipo, 'estado', new.estado,
        'cliente', new.nombre_cliente, 'nuevos', nuevos);
    else
      ev := jsonb_build_object('tabla', 'solicitudes', 'id', new.id, 'codigo', new.codigo, 'tipo', new.tipo, 'estado', new.estado,
        'antes', case when tg_op = 'UPDATE' then old.estado end, 'cliente', new.nombre_cliente,
        'asesor', new.asesor_id, 'analista', new.analista_id, 'verificador', new.verificador_id,
        'verificador_trabajo', case when new.verificador_trabajo_id is distinct from new.verificador_id then new.verificador_trabajo_id end);
    end if;
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
  return null;
end $function$;

drop trigger if exists push_solicitudes on public.solicitudes;
create trigger push_solicitudes after insert or update of estado, verificador_id, verificador_trabajo_id on public.solicitudes
  for each row execute function private.push_evento();

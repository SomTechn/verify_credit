-- Refinanciamiento: al cargar un corte nuevo se empieza a marcar de cero.
-- Se borran: aplica / no aplica, contactado y colocado.
-- Se conservan: límite, nivel, comentario y bloqueo.
-- Lo borrado queda guardado en historial (últimas 20 entradas por cliente).
create or replace function public.refi_reiniciar_marcas(p_corte bigint default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n integer;
  v_corte date;
  v_hoy date := (now() at time zone 'America/Tegucigalpa')::date;
begin
  if coalesce(public.mi_rol(), '') not in ('analista', 'admin') then
    raise exception 'Solo el analista puede reiniciar las marcas de refinanciamiento';
  end if;
  if p_corte is not null then
    select fecha_corte into v_corte from public.refi_cortes where id = p_corte;
  end if;

  with nuevos as (
    select c.clave,
      (case when jsonb_typeof(c.historial) = 'array' then c.historial else '[]'::jsonb end)
        || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
             'reinicio', v_hoy, 'corte_nuevo', v_corte, 'aplica', c.aplica,
             'contactado', nullif(c.contactado, false), 'fecha_contacto', c.fecha_contacto,
             'monto', c.monto_colocado, 'fecha', c.fecha_colocado))) as h
    from public.refi_clientes c
    where c.aplica is not null or c.contactado or c.colocado
  )
  update public.refi_clientes c set
    historial = (select coalesce(jsonb_agg(e order by i), '[]'::jsonb)
                 from jsonb_array_elements(n.h) with ordinality t(e, i)
                 where i > jsonb_array_length(n.h) - 20),
    aplica = null, contactado = false, fecha_contacto = null,
    colocado = false, monto_colocado = null, fecha_colocado = null,
    actualizado_por = auth.uid(), actualizado_en = now()
  from nuevos n
  where c.clave = n.clave;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.refi_reiniciar_marcas(bigint) from public, anon;
grant execute on function public.refi_reiniciar_marcas(bigint) to authenticated;

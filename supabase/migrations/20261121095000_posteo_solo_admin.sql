-- Posteo en sistema general: solo administrador
drop policy if exists posteos_sel on public.posteos;
create policy posteos_sel on public.posteos for select using (public.mi_rol() = 'admin');

create or replace function public.posteo_marcar(p_id bigint, p_paso text, p_hecho boolean default true, p_banco text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador'; end if;
  return _posteo_guardar(p_id, case when p_paso is null then '{}'::text[] else array[p_paso] end, p_hecho, p_banco, null);
end $$;

create or replace function public.posteo_marcar_hasta(p_hasta date, p_nota text default 'Marcado en lote (ya estaba posteado)')
returns integer language plpgsql security definer set search_path = public as $$
declare s solicitudes; n int := 0;
begin
  if coalesce(mi_rol(), '') <> 'admin' then raise exception 'Solo el administrador'; end if;
  for s in select * from solicitudes x where x.estado = 'desembolsada' and not coalesce(x.importado, false)
             and coalesce(x.fecha_colocacion, (x.desembolsado_en at time zone 'America/Tegucigalpa')::date) <= p_hasta
             and not exists (select 1 from posteos p where p.solicitud_id = x.id and p.completo_en is not null)
  loop
    perform _posteo_guardar(s.id, posteo_pasos_req(s), true, null, p_nota);
    n := n + 1;
  end loop;
  return n;
end $$;

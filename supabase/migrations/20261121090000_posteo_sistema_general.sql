-- Posteo en el sistema general de las solicitudes desembolsadas.
-- Pasos: desembolso (préstamo en el sistema general), intereses y capital (solo refi/reingreso con saldo),
-- ingreso y traslado de fondos banco → caja.
create table if not exists public.posteos (
  solicitud_id bigint primary key references public.solicitudes(id) on delete cascade,
  banco text not null default 'BAC',
  pasos jsonb not null default '{}'::jsonb,       -- { paso: { en, por } }
  completo_en timestamptz,
  completo_por uuid references public.perfiles(id),
  nota text,
  actualizado_en timestamptz not null default now(),
  actualizado_por uuid references public.perfiles(id)
);
alter table public.posteos enable row level security;
drop policy if exists posteos_sel on public.posteos;
create policy posteos_sel on public.posteos for select using (public.tiene_rol('analista'));

insert into public.parametros (clave, valor, descripcion)
values ('posteo_desde', 20261109, 'Posteo en sistema general: mostrar desembolsos desde esta fecha (AAAAMMDD)')
on conflict (clave) do nothing;

-- Pasos que exige cada solicitud
create or replace function public.posteo_pasos_req(s public.solicitudes)
returns text[] language sql immutable as $$
  select array['desembolso']
    || case when s.tipo <> 'nuevo' and coalesce(s.saldo_intereses, 0) > 0 then array['intereses'] else '{}'::text[] end
    || case when s.tipo <> 'nuevo' and coalesce(s.saldo_capital, 0) > 0 then array['capital'] else '{}'::text[] end
    || array['ingreso', 'traslado'];
$$;

create or replace function public._posteo_guardar(p_id bigint, p_pasos text[], p_hecho boolean, p_banco text, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s solicitudes; r posteos; req text[]; k text; completo boolean;
begin
  select * into s from solicitudes where id = p_id;
  if not found or s.estado <> 'desembolsada' then raise exception 'La solicitud no está desembolsada'; end if;
  insert into posteos (solicitud_id) values (p_id) on conflict do nothing;
  select * into r from posteos where solicitud_id = p_id for update;
  foreach k in array p_pasos loop
    if k not in ('desembolso', 'intereses', 'capital', 'ingreso', 'traslado') then raise exception 'Paso inválido: %', k; end if;
    if p_hecho then r.pasos := r.pasos || jsonb_build_object(k, jsonb_build_object('en', now(), 'por', auth.uid()));
    else r.pasos := r.pasos - k; end if;
  end loop;
  req := posteo_pasos_req(s);
  completo := not exists (select 1 from unnest(req) x where not (r.pasos ? x));
  update posteos set pasos = r.pasos,
    banco = coalesce(nullif(trim(p_banco), ''), banco),
    nota = coalesce(p_nota, nota),
    completo_en = case when completo then coalesce(completo_en, now()) end,
    completo_por = case when completo then coalesce(completo_por, auth.uid()) end,
    actualizado_en = now(), actualizado_por = auth.uid()
  where solicitud_id = p_id returning * into r;
  return to_jsonb(r);
end $$;

-- Marcar / desmarcar un paso (o cambiar el banco con p_paso = null)
create or replace function public.posteo_marcar(p_id bigint, p_paso text, p_hecho boolean default true, p_banco text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not tiene_rol('analista') then raise exception 'Sin permiso'; end if;
  return _posteo_guardar(p_id, case when p_paso is null then '{}'::text[] else array[p_paso] end, p_hecho, p_banco, null);
end $$;

-- Marcar como ya posteadas (todas sus pasos) las desembolsadas hasta una fecha de colocación
create or replace function public.posteo_marcar_hasta(p_hasta date, p_nota text default 'Marcado en lote (ya estaba posteado)')
returns integer language plpgsql security definer set search_path = public as $$
declare s solicitudes; n int := 0;
begin
  if not tiene_rol('analista') then raise exception 'Sin permiso'; end if;
  for s in select * from solicitudes x where x.estado = 'desembolsada' and not coalesce(x.importado, false)
             and coalesce(x.fecha_colocacion, (x.desembolsado_en at time zone 'America/Tegucigalpa')::date) <= p_hasta
             and not exists (select 1 from posteos p where p.solicitud_id = x.id and p.completo_en is not null)
  loop
    perform _posteo_guardar(s.id, posteo_pasos_req(s), true, null, p_nota);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public._posteo_guardar(bigint, text[], boolean, text, text) from public, anon, authenticated;
revoke all on function public.posteo_marcar(bigint, text, boolean, text) from public, anon;
revoke all on function public.posteo_marcar_hasta(date, text) from public, anon;
grant execute on function public.posteo_marcar(bigint, text, boolean, text) to authenticated;
grant execute on function public.posteo_marcar_hasta(date, text) to authenticated;

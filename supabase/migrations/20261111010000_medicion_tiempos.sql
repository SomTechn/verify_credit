-- Medición de tiempos (11-nov-2026)
-- 1) Motivo de espera con categoría fija (cliente / equipo) y registro de cada espera con su duración
-- 2) Reporte "¿Dónde se va el tiempo?" (pasos, esperas, verificación por tramos, por persona)
-- Solo agrega: no cambia estados ni datos existentes.

alter table public.solicitudes add column if not exists espera_categoria text;

create or replace function public.espera_quien(p_cat text) returns text
language sql immutable set search_path to 'public' as $$
  select case
    when p_cat in ('documentos','no_contesta','cliente_decide','cliente_ausente') then 'cliente'
    when p_cat in ('autorizacion','fondos','sin_verificador') then 'equipo'
    else 'otro' end;
$$;

create table if not exists public.esperas (
  id bigint generated always as identity primary key,
  solicitud_id bigint not null references public.solicitudes(id) on delete cascade,
  estado text not null,
  categoria text,
  motivo text,
  desde timestamptz not null,
  hasta timestamptz,
  seg integer,
  habil_seg integer,
  puesto_por uuid,
  reanudado_por uuid
);
create index if not exists esperas_solicitud_idx on public.esperas (solicitud_id);
create index if not exists esperas_desde_idx on public.esperas (desde);
alter table public.esperas enable row level security;
drop policy if exists esperas_sel on public.esperas;
create policy esperas_sel on public.esperas for select to authenticated using (public.mi_rol() is not null);
revoke all on public.esperas from anon;
grant select on public.esperas to authenticated;

-- La categoría solo vive mientras la solicitud está en espera
create or replace function public.tg_espera_categoria() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if not coalesce(new.en_espera, false) then new.espera_categoria := null; end if;
  return new;
end $$;
drop trigger if exists zz_espera_categoria on public.solicitudes;
create trigger zz_espera_categoria before update on public.solicitudes
  for each row execute function public.tg_espera_categoria();

-- Cada espera queda registrada (abre al pausar, cierra al reanudar: manual o automático)
create or replace function public.tg_esperas() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(new.en_espera, false) and not coalesce(old.en_espera, false) then
    insert into esperas (solicitud_id, estado, categoria, motivo, desde, puesto_por)
    values (new.id, new.estado, new.espera_categoria, new.espera_motivo, coalesce(new.espera_desde, now()), coalesce(new.espera_por, auth.uid()));
  elsif coalesce(old.en_espera, false) and not coalesce(new.en_espera, false) then
    update esperas set hasta = now(),
      seg = round(extract(epoch from now() - desde))::int,
      habil_seg = coalesce(segundos_habiles(desde, now()), 0),
      reanudado_por = auth.uid()
    where solicitud_id = new.id and hasta is null;
  end if;
  return null;
end $$;
drop trigger if exists esperas_registro on public.solicitudes;
create trigger esperas_registro after update on public.solicitudes
  for each row when (old.en_espera is distinct from new.en_espera)
  execute function public.tg_esperas();

-- poner_en_espera acepta la categoría (opcional: las versiones anteriores de la app siguen funcionando)
drop function if exists public.poner_en_espera(bigint, text);
create or replace function public.poner_en_espera(p_id bigint, p_motivo text, p_categoria text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s solicitudes;
begin
  if not tiene_rol('asesor','analista','verificador') then raise exception 'Sin permiso'; end if;
  s := _bloquear(p_id);
  if s.estado in ('desembolsada','denegada','rechazada_verificacion','desistida') then raise exception 'La solicitud ya está cerrada'; end if;
  if s.en_espera then raise exception 'La solicitud ya está en espera'; end if;
  if length(trim(coalesce(p_motivo,''))) = 0 then raise exception 'Indique el motivo de la espera'; end if;
  if p_categoria is not null and p_categoria not in ('documentos','no_contesta','cliente_decide','cliente_ausente','autorizacion','fondos','sin_verificador','otro') then
    raise exception 'Motivo de espera no válido'; end if;
  update solicitudes set en_espera = true, espera_motivo = trim(p_motivo), espera_categoria = p_categoria, espera_desde = now(), espera_por = auth.uid() where id = p_id;
  perform _evento(p_id, 'en_espera', null, null, p_motivo);
end $$;
revoke all on function public.poner_en_espera(bigint, text, text) from public, anon;
grant execute on function public.poner_en_espera(bigint, text, text) to authenticated, service_role;

-- Historial: reconstruye las esperas anteriores a partir de los eventos
insert into public.esperas (solicitud_id, estado, categoria, motivo, desde, hasta, seg, habil_seg, puesto_por, reanudado_por)
select e.solicitud_id,
  coalesce((select x.a_estado from eventos x where x.solicitud_id = e.solicitud_id and x.a_estado is not null and x.creado_en <= e.creado_en order by x.creado_en desc, x.id desc limit 1), 'borrador'),
  case when e.nota ~* '(voucher|document|comprobante|constancia|boleta|papel)' then 'documentos'
       when e.nota ~* '(no contest|no da respuesta|no respond|no atend)' then 'no_contesta'
       when e.nota ~* '(nery|autoriz|gerenc)' then 'autorizacion'
       else null end,
  e.nota, e.creado_en, r.creado_en,
  case when r.creado_en is not null then round(extract(epoch from r.creado_en - e.creado_en))::int end,
  case when r.creado_en is not null then coalesce(segundos_habiles(e.creado_en, r.creado_en), 0) end,
  e.usuario_id, r.usuario_id
from eventos e
left join lateral (select x.creado_en, x.usuario_id from eventos x where x.solicitud_id = e.solicitud_id and x.accion = 'reanudada' and x.creado_en >= e.creado_en order by x.creado_en, x.id limit 1) r on true
join solicitudes s on s.id = e.solicitud_id
where e.accion = 'en_espera'
  and not exists (select 1 from esperas z where z.solicitud_id = e.solicitud_id and z.desde = e.creado_en)
  and (r.creado_en is not null or s.en_espera);

-- Reporte: ¿dónde se va el tiempo?
create or replace function public.reporte_tiempos(p_desde date, p_hasta date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare d0 timestamptz; d1 timestamptz; r jsonb;
  pasos text[] := array['borrador','en_analisis','aprobada','por_verificar','desembolso_pendiente'];
begin
  if mi_rol() is null then raise exception 'Sin permiso'; end if;
  d0 := (p_desde::timestamp) at time zone 'America/Tegucigalpa';
  d1 := ((p_hasta + 1)::timestamp) at time zone 'America/Tegucigalpa';
  with ev as (
    select e.*, s.asesor_id, s.verificador_id, s.nombre_cliente, s.codigo
    from eventos e join solicitudes s on s.id = e.solicitud_id
    where e.creado_en >= d0 and e.creado_en < d1 and e.de_estado = any(pasos)
      and e.a_estado is not null and e.a_estado <> e.de_estado and e.duracion_habil_seg is not null
      and not coalesce(s.importado, false)
  ),
  esp as (
    select w.*, espera_quien(w.categoria) quien,
      coalesce(w.habil_seg, segundos_habiles(w.desde, now()), 0) hs
    from esperas w where w.desde >= d0 and w.desde < d1
  ),
  ver as (
    select v.*, least(greatest(coalesce(v.t_asig0, v.t0), v.t0), v.t1) t_asig,
      least(greatest(coalesce(v.t_vis0, v.t1), v.t0), v.t1) t_vis
    from (
      select e.solicitud_id, e.verificador_id, e.creado_en t1,
        e.creado_en - make_interval(secs => e.duracion_seg) t0,
        (select min(x.creado_en) from eventos x where x.solicitud_id = e.solicitud_id and x.accion = 'verificador_asignado'
            and coalesce(x.nota,'') <> 'Sin asignar' and x.creado_en <= e.creado_en
            and x.creado_en >= e.creado_en - make_interval(secs => e.duracion_seg)
            and not exists (select 1 from eventos y where y.solicitud_id = e.solicitud_id and y.accion = 'verificador_asignado'
              and coalesce(y.nota,'') <> 'Sin asignar' and y.creado_en < e.creado_en - make_interval(secs => e.duracion_seg))) t_asig0,
        (select min(vi.creado_en) from visitas vi where vi.solicitud_id = e.solicitud_id and vi.creado_en <= e.creado_en
            and vi.creado_en >= e.creado_en - make_interval(secs => e.duracion_seg)) t_vis0
      from ev e where e.de_estado = 'por_verificar' and e.a_estado in ('desembolsada','desembolso_pendiente','rechazada_verificacion') and e.duracion_seg is not null
    ) v
  ),
  ver2 as (
    select solicitud_id, verificador_id,
      coalesce(segundos_habiles(t0, t_asig), 0) s_asig,
      coalesce(segundos_habiles(least(t_asig, t_vis), t_vis), 0) s_ruta,
      coalesce(segundos_habiles(t_vis, t1), 0) s_cierre,
      coalesce(segundos_habiles(t0, t1), 0) s_total
    from ver
  )
  select jsonb_build_object(
    'por_paso', (select coalesce(jsonb_agg(to_jsonb(x) order by x.orden), '[]') from (
        select e.de_estado estado, array_position(pasos, e.de_estado) orden, count(*) n,
          round(percentile_cont(0.5) within group (order by e.duracion_habil_seg)) mediana_seg,
          round(percentile_cont(0.9) within group (order by e.duracion_habil_seg)) p90_seg,
          round(avg(e.duracion_habil_seg)) prom_seg, sum(e.duracion_habil_seg) total_seg,
          count(*) filter (where e.duracion_habil_seg > p('meta_paso_min') * 60) fuera_meta,
          coalesce((select sum(w.hs) from esp w where w.estado = e.de_estado and w.quien = 'cliente'), 0) espera_cliente_seg,
          coalesce((select sum(w.hs) from esp w where w.estado = e.de_estado and w.quien <> 'cliente'), 0) espera_equipo_seg
        from ev e where e.a_estado <> 'desistida' group by e.de_estado) x),
    'desistidas', (select coalesce(jsonb_agg(to_jsonb(x) order by x.orden), '[]') from (
        select e.de_estado estado, array_position(pasos, e.de_estado) orden, count(*) n,
          round(percentile_cont(0.5) within group (order by e.duracion_habil_seg)) mediana_seg, sum(e.duracion_habil_seg) total_seg
        from ev e where e.a_estado = 'desistida' group by e.de_estado) x),
    'esperas', (select coalesce(jsonb_agg(to_jsonb(x) order by x.total_seg desc), '[]') from (
        select coalesce(w.categoria, 'sin_clasificar') categoria, w.quien, count(*) n, sum(w.hs) total_seg,
          round(percentile_cont(0.5) within group (order by w.hs)) mediana_seg,
          count(*) filter (where w.hasta is null) abiertas
        from esp w group by 1, 2) x),
    'verificacion', (select jsonb_build_object('n', count(*),
          'asignar_mediana', round(percentile_cont(0.5) within group (order by s_asig)), 'asignar_total', sum(s_asig),
          'ruta_mediana', round(percentile_cont(0.5) within group (order by s_ruta)), 'ruta_total', sum(s_ruta),
          'cierre_mediana', round(percentile_cont(0.5) within group (order by s_cierre)), 'cierre_total', sum(s_cierre),
          'total_mediana', round(percentile_cont(0.5) within group (order by s_total))) from ver2),
    'por_verificador', (select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc), '[]') from (
        select coalesce(pf.nombre, 'Sin asignar') nombre, count(*) n,
          round(percentile_cont(0.5) within group (order by v.s_total)) mediana_seg,
          round(percentile_cont(0.5) within group (order by v.s_ruta)) ruta_mediana_seg,
          round(percentile_cont(0.9) within group (order by v.s_total)) p90_seg
        from ver2 v left join perfiles pf on pf.id = v.verificador_id group by 1) x),
    'por_asesor', (select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc), '[]') from (
        select pf.nombre, count(*) filter (where e.de_estado = 'borrador') n,
          round(percentile_cont(0.5) within group (order by e.duracion_habil_seg) filter (where e.de_estado = 'borrador')) captura_mediana_seg,
          round(percentile_cont(0.9) within group (order by e.duracion_habil_seg) filter (where e.de_estado = 'borrador')) captura_p90_seg,
          round(percentile_cont(0.5) within group (order by e.duracion_habil_seg) filter (where e.de_estado = 'aprobada')) completar_mediana_seg
        from ev e join perfiles pf on pf.id = e.asesor_id
        where e.de_estado in ('borrador','aprobada') and e.a_estado <> 'desistida' group by pf.nombre) x),
    'por_analista', (select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc), '[]') from (
        select pf.nombre, e.de_estado estado, count(*) n,
          round(percentile_cont(0.5) within group (order by e.duracion_habil_seg)) mediana_seg,
          round(percentile_cont(0.9) within group (order by e.duracion_habil_seg)) p90_seg
        from ev e join perfiles pf on pf.id = e.usuario_id
        where e.de_estado in ('en_analisis','desembolso_pendiente') and e.a_estado in ('aprobada','denegada','desembolsada') group by pf.nombre, e.de_estado) x),
    'lentas', (select coalesce(jsonb_agg(to_jsonb(x) order by x.seg desc), '[]') from (
        select e.solicitud_id id, e.nombre_cliente cliente, e.codigo, e.de_estado estado, e.a_estado, e.duracion_habil_seg seg
        from ev e where e.a_estado <> 'desistida' order by e.duracion_habil_seg desc limit 10) x),
    'meta_paso_min', p('meta_paso_min')
  ) into r;
  return r;
end $$;
revoke all on function public.reporte_tiempos(date, date) from public, anon;
grant execute on function public.reporte_tiempos(date, date) to authenticated, service_role;

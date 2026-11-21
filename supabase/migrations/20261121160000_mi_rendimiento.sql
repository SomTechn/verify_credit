-- Rendimiento personal para "Mi trabajo": tiempo hábil por paso que completa el usuario,
-- hoy contra sus últimos 30 días (promedio sin el 10% más lento, para que un caso atípico no lo distorsione).
create or replace function public.mi_rendimiento()
returns jsonb language sql stable security definer set search_path = public as $$
  with hoy as (select (now() at time zone 'America/Tegucigalpa')::date d),
  ev as (
    select e.de_estado, e.duracion_habil_seg::numeric seg, (e.creado_en at time zone 'America/Tegucigalpa')::date dia
    from eventos e join solicitudes s on s.id = e.solicitud_id
    where e.usuario_id = auth.uid()
      and e.de_estado in ('borrador','cola_analisis','en_analisis','aprobada','por_verificar','desembolso_pendiente')
      and e.a_estado is not null and e.a_estado <> e.de_estado and e.a_estado <> 'desistida'
      and e.duracion_habil_seg is not null and not coalesce(s.importado, false)
      and e.creado_en >= now() - interval '31 days'
  ),
  lim as (
    select de_estado, percentile_cont(.9) within group (order by seg) p90
    from ev, hoy where dia < hoy.d group by de_estado
  )
  select coalesce(jsonb_object_agg(x.de_estado, jsonb_build_object(
      'hoy_n', x.hoy_n, 'hoy_prom', x.hoy_prom, 'n30', x.n30, 'prom30', x.prom30, 'dias30', x.dias30)), '{}'::jsonb)
  from (
    select ev.de_estado,
      count(*) filter (where dia = hoy.d) hoy_n,
      round(avg(least(seg, coalesce(lim.p90, seg))) filter (where dia = hoy.d)) hoy_prom,
      count(*) filter (where dia < hoy.d) n30,
      round(avg(seg) filter (where dia < hoy.d and seg <= coalesce(lim.p90, seg))) prom30,
      count(distinct dia) filter (where dia < hoy.d) dias30
    from ev cross join hoy left join lim on lim.de_estado = ev.de_estado
    group by ev.de_estado
  ) x;
$$;
revoke all on function public.mi_rendimiento() from public, anon;
grant execute on function public.mi_rendimiento() to authenticated;

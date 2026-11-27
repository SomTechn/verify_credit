-- Confirmar el desembolso (transferencia) es responsabilidad del gerente: ese paso ya no cuenta en el tiempo
-- ni en el rendimiento del analista (Mi rendimiento, bandeja limpia y promedio por persona en Estadísticas).
do $$
declare d text;
begin
  -- Mi rendimiento: sin el paso de desembolso
  d := pg_get_functiondef('public.mi_rendimiento()'::regprocedure);
  if position($q$'por_verificar','desembolso_pendiente')$q$ in d) = 0 then raise exception 'mi_rendimiento cambió: revisar'; end if;
  execute replace(d, $q$'por_verificar','desembolso_pendiente')$q$, $q$'por_verificar')$q$);
  -- Estadísticas: el promedio por persona no incluye confirmar desembolsos
  d := pg_get_functiondef('public.estadisticas_tiempos(date,date)'::regprocedure);
  if position($q$and e.accion not in ('desistida','regresada_revisadas','analisis_tomado')$q$ in d) = 0 then raise exception 'estadisticas_tiempos cambió: revisar'; end if;
  execute replace(d, $q$and e.accion not in ('desistida','regresada_revisadas','analisis_tomado')$q$,
    $q$and e.accion not in ('desistida','regresada_revisadas','analisis_tomado') and e.de_estado <> 'desembolso_pendiente'$q$);
end $$;

-- Bandeja limpia y rachas: confirmar desembolsos no cuenta como paso completado
create or replace function public._pasos_completados()
returns text[] language sql immutable as $$ select array['borrador','en_analisis','aprobada','por_verificar'] $$;

-- Las coordenadas de la verificación ya no se pueden leer directo de la tabla: solo por verif_gps() / visitas_mapa()
-- (admin o usuarios con perfiles.ver_gps). La app (APP_VER 2026-11-25.1430) ya pide columnas explícitas.
revoke select on public.verificacion_items from anon, authenticated;
grant select (id, solicitud_id, item, completado, nota, foto_path, actualizado_por, actualizado_en, en_camino_en, llegada_en, completado_en)
  on public.verificacion_items to authenticated;

revoke select on public.visitas from anon, authenticated;
grant select (id, solicitud_id, verificador_id, tipo, resultado, creado_en, item_id, nombre_cliente) on public.visitas to authenticated;

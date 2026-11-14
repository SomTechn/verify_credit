-- Pestaña "Prospectos" de VerifyCredit: los prospectos que guarda el bot de WhatsApp (bot_leads)
-- se actualizan en pantalla en tiempo real. La lectura sigue protegida por las políticas RLS de la tabla.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bot_leads') then
    alter publication supabase_realtime add table public.bot_leads;
  end if;
end $$;

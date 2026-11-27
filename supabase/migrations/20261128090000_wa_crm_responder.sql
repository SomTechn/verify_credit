-- CRM WhatsApp, fase 3: responder desde VerifyCredit y tomar o soltar el bot por conversación.
-- El envío lo hace la función wa-enviar (con la clave de API de BuilderBot guardada como secreto).

alter table public.wa_conversaciones add column if not exists atendido_por uuid references public.perfiles(id) on delete set null;
alter table public.wa_conversaciones add column if not exists atendido_en timestamptz;
alter table public.wa_mensajes add column if not exists enviado_por uuid references public.perfiles(id) on delete set null;

-- Guarda un mensaje enviado por un asesor desde VerifyCredit (lo llama wa-enviar con service_role)
create or replace function public.wa_guardar_envio(p_tel text, p_texto text, p_usuario uuid)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint;
begin
  insert into wa_conversaciones (telefono, ultimo_texto, ultimo_autor, ultimo_en, no_leidos)
  values (p_tel, p_texto, 'asesor', now(), 0)
  on conflict (telefono) do update set ultimo_texto = excluded.ultimo_texto, ultimo_autor = 'asesor', ultimo_en = now(), no_leidos = 0;
  insert into wa_mensajes (telefono, autor, tipo, texto, enviado_en, enviado_por)
  values (p_tel, 'asesor', 'text', p_texto, now(), p_usuario)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.wa_guardar_envio(text, text, uuid) from public, anon, authenticated;

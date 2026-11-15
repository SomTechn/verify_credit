// VerifyCredit · consulta de estado para el bot de WhatsApp (BuilderBot).
// POST { telefono, dni? } con cabecera x-bot-token (el mismo token de la función `bot`, tabla bot_config).
// Responde { ok, resultado, mensaje }. La lógica y las reglas de privacidad están en la función SQL bot_estado.
// Al cambiarla hay que DESPLEGARLA (verify_jwt = false).
import { createClient } from "jsr:@supabase/supabase-js@2";

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, mensaje: "Use POST" }, 405);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: cfg } = await sb.from("bot_config").select("valor").eq("clave", "token").maybeSingle();
  const token = req.headers.get("x-bot-token") || "";
  if (!cfg?.valor || token !== cfg.valor) return json({ ok: false, mensaje: "Token inválido" }, 401);
  let b: Record<string, unknown> = {};
  try { b = await req.json(); } catch (_) { /* cuerpo vacío */ }
  const { data, error } = await sb.rpc("bot_estado", { p_tel: String(b.telefono ?? ""), p_dni: String(b.dni ?? "") });
  if (error) {
    console.error(error);
    return json({ ok: false, resultado: "error", mensaje: "En este momento no pudimos consultar su solicitud. Un asesor le ayudará por este chat." });
  }
  return json(data);
});

// CRM WhatsApp, fase 3: acciones del asesor desde VerifyCredit.
//   { accion: "enviar", telefono, texto }  → manda el texto al cliente por el bot y toma la conversación
//   { accion: "tomar",  telefono }          → el bot deja de contestarle a ese número (lista negra de BuilderBot)
//   { accion: "soltar", telefono }          → el bot vuelve a atender ese número
// Solo usuarios con perfiles.ver_whatsapp. Desplegada con verify_jwt = true (sesión de VerifyCredit).
// Secreto necesario: BUILDERBOT_API_KEY (Supabase → Edge Functions → Secrets).
import { createClient } from "jsr:@supabase/supabase-js@2";

const PROYECTO = "794f44ed-2dae-4e4b-8119-c667cddfdcd5";
const BB = "https://app.builderbot.cloud";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resp = (b: unknown, status = 200) => Response.json(b, { status, headers: CORS });

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

async function bb(metodo: string, ruta: string, cuerpo: unknown) {
  const clave = Deno.env.get("BUILDERBOT_API_KEY");
  if (!clave) throw new Error("Falta configurar la clave de API de BuilderBot (secreto BUILDERBOT_API_KEY)");
  const r = await fetch(BB + ruta, {
    method: metodo,
    headers: { "x-api-builderbot": clave, "Content-Type": "application/json" },
    body: JSON.stringify(cuerpo),
  });
  const txt = await r.text();
  if (!r.ok) throw new Error(`BuilderBot respondió ${r.status}: ${txt.slice(0, 200)}`);
  return txt;
}

async function tomar(tel: string, usuario: string) {
  await bb("POST", `/api/v1/manager/project/${PROYECTO}/blacklist`, { phones: [tel] });
  await admin.from("wa_conversaciones").update({ atendido_por: usuario, atendido_en: new Date().toISOString() }).eq("telefono", tel);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resp({ ok: false, error: "Método no permitido" }, 405);
  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(jwt);
    if (!u?.user) return resp({ ok: false, error: "Sesión no válida" }, 401);
    const { data: perfil } = await admin.from("perfiles").select("id, ver_whatsapp, activo").eq("id", u.user.id).maybeSingle();
    if (!perfil?.ver_whatsapp || perfil.activo === false) return resp({ ok: false, error: "No tiene permiso para los chats de WhatsApp" }, 403);

    const body = await req.json().catch(() => ({}));
    const accion = String(body.accion ?? "");
    const tel = String(body.telefono ?? "").replace(/\D/g, "");
    if (tel.length < 8) return resp({ ok: false, error: "Teléfono no válido" }, 400);

    if (accion === "tomar") {
      await tomar(tel, perfil.id);
      return resp({ ok: true });
    }
    if (accion === "soltar") {
      await bb("DELETE", `/api/v1/manager/project/${PROYECTO}/blacklist`, { phones: [tel] });
      await admin.from("wa_conversaciones").update({ atendido_por: null, atendido_en: null }).eq("telefono", tel);
      return resp({ ok: true });
    }
    if (accion === "enviar") {
      const texto = String(body.texto ?? "").trim();
      if (!texto) return resp({ ok: false, error: "Escriba un mensaje" }, 400);
      if (texto.length > 4000) return resp({ ok: false, error: "El mensaje es demasiado largo" }, 400);
      // Quien contesta toma la conversación, para que el bot no responda encima
      const { data: conv } = await admin.from("wa_conversaciones").select("atendido_por").eq("telefono", tel).maybeSingle();
      if (!conv?.atendido_por) await tomar(tel, perfil.id);
      await bb("POST", `/api/v2/${PROYECTO}/messages`, { messages: { content: texto }, number: tel, checkIfExists: false });
      const { data: id, error } = await admin.rpc("wa_guardar_envio", { p_tel: tel, p_texto: texto, p_usuario: perfil.id });
      if (error) console.error("wa_guardar_envio", error.message);
      return resp({ ok: true, id });
    }
    return resp({ ok: false, error: "Acción no válida" }, 400);
  } catch (e) {
    console.error("wa-enviar", (e as Error).message);
    return resp({ ok: false, error: (e as Error).message }, 502);
  }
});

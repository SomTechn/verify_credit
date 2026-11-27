// Recibe los eventos del webhook de BuilderBot y los guarda tal cual en wa_eventos.
// Solo acepta llamadas con el encabezado x-webhook-token igual a bot_config.webhook_token.
// Desplegada con verify_jwt = false (la autenticación es el token).
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

let tokenCache: { valor: string; hasta: number } | null = null;

async function tokenValido(): Promise<string | null> {
  if (tokenCache && tokenCache.hasta > Date.now()) return tokenCache.valor;
  const { data } = await sb.from("bot_config").select("valor").eq("clave", "webhook_token").maybeSingle();
  if (!data?.valor) return null;
  tokenCache = { valor: data.valor, hasta: Date.now() + 5 * 60 * 1000 };
  return data.valor;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok", { status: 200 });
  const esperado = await tokenValido();
  const recibido = req.headers.get("x-webhook-token") ?? "";
  if (!esperado || recibido !== esperado) {
    return Response.json({ ok: false, error: "no autorizado" }, { status: 401 });
  }
  const texto = await req.text();
  let payload: unknown;
  try {
    payload = JSON.parse(texto);
  } catch {
    payload = { raw: texto };
  }
  const { error } = await sb.from("wa_eventos").insert({ payload });
  if (error) {
    console.error("insert wa_eventos", error.message);
    return Response.json({ ok: false }, { status: 500 });
  }
  return Response.json({ ok: true });
});

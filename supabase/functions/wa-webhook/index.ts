// Recibe los eventos del webhook de BuilderBot.
// 1) Guarda cada evento tal cual en wa_eventos.
// 2) Si es un mensaje (entrante o saliente), lo pasa a wa_conversaciones / wa_mensajes.
// 3) Si trae foto o archivo, lo descarga en ese momento (las URL vencen) y lo sube al bucket privado wa-media.
// Solo acepta llamadas con el encabezado x-webhook-token igual a bot_config.webhook_token.
// Desplegada con verify_jwt = false (la autenticación es el token).
// Body {"reprocesar": true} (con el mismo token) pasa a mensajes los eventos que aún no lo estén.
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const MEDIA = new Set(["image", "document", "audio", "video", "sticker"]);
const EXT: Record<string, string> = {
  "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "application/pdf": "pdf",
  "audio/ogg": "ogg", "audio/mpeg": "mp3", "video/mp4": "mp4",
};

let tokenCache: { valor: string; hasta: number } | null = null;

async function tokenValido(): Promise<string | null> {
  if (tokenCache && tokenCache.hasta > Date.now()) return tokenCache.valor;
  const { data } = await sb.from("bot_config").select("valor").eq("clave", "webhook_token").maybeSingle();
  if (!data?.valor) return null;
  tokenCache = { valor: data.valor, hasta: Date.now() + 5 * 60 * 1000 };
  return data.valor;
}

const digitos = (s: unknown) => String(s ?? "").replace(/\D/g, "");

function fecha(ts: unknown): string {
  const n = Number(ts);
  if (!Number.isFinite(n) || n <= 0) return new Date().toISOString();
  return new Date(n < 1e12 ? n * 1000 : n).toISOString();
}

// deno-lint-ignore no-explicit-any
async function guardarMedia(id: number, tel: string, d: any) {
  const raw = d.raw ?? {};
  const info = d.fileData ?? raw[d.type] ?? {};
  const mime: string = info.mime_type ?? "";
  const urls = [d.urlTempFile, ...(Array.isArray(d.urlsTempsFiles) ? d.urlsTempsFiles : []), d.url, info.url]
    .filter((u) => typeof u === "string" && u.startsWith("https://"));
  for (const u of [...new Set(urls)]) {
    try {
      const r = await fetch(u);
      if (!r.ok) { console.error("media", r.status, u.split("?")[0]); continue; }
      const tipo = mime || r.headers.get("content-type") || "application/octet-stream";
      const ext = EXT[tipo.split(";")[0]] ?? (String(d.attachment?.[0] ?? "").split(".").pop() || "bin");
      const ruta = `${tel}/${id}.${ext}`;
      const bytes = new Uint8Array(await r.arrayBuffer());
      const { error } = await sb.storage.from("wa-media").upload(ruta, bytes, { contentType: tipo, upsert: true });
      if (error) { console.error("upload", error.message); continue; }
      await sb.from("wa_mensajes").update({ media_path: ruta, media_mime: tipo, media_estado: "guardada" }).eq("id", id);
      return;
    } catch (e) {
      console.error("media", (e as Error).message);
    }
  }
  await sb.from("wa_mensajes").update({ media_estado: "error" }).eq("id", id);
}

// deno-lint-ignore no-explicit-any
async function procesar(eventoId: number, payload: any, recibido?: string) {
  const ev = payload?.eventName;
  const d = payload?.data;
  if (!d || (ev !== "message.incoming" && ev !== "message.outgoing")) return;
  const tel = digitos(d.from);
  if (tel.length < 8) return;

  const saliente = ev === "message.outgoing";
  const autor = saliente ? "bot" : (d.fromMe === true ? "asesor" : "cliente");
  const tipo = saliente ? "text" : String(d.type ?? d.contentType ?? "text");
  let texto: string = typeof d.body === "string" ? d.body : "";
  if (texto.startsWith("_event_")) texto = "";
  const raw = d.raw ?? {};
  if (!texto && raw[tipo]?.caption) texto = String(raw[tipo].caption);
  const esMedia = MEDIA.has(tipo);
  if (!texto && !esMedia) return;

  // Un mensaje que mandó un asesor desde VerifyCredit (wa-enviar) vuelve como "saliente": no duplicarlo como del bot
  if (saliente && texto) {
    const desde = new Date(Date.now() - 5 * 60 * 1000).toISOString();
    const { data: ya } = await sb.from("wa_mensajes").select("id").eq("telefono", tel).eq("autor", "asesor")
      .eq("texto", texto).gte("enviado_en", desde).limit(1);
    if (ya?.length) return;
  }

  const { data: id, error } = await sb.rpc("wa_guardar_mensaje", {
    p_tel: tel,
    p_nombre: saliente ? "" : String(d.pushName ?? d.name ?? ""),
    p_wamid: saliente ? "" : String(d.messageId ?? d.message_id ?? raw.id ?? ""),
    p_autor: autor,
    p_tipo: tipo,
    p_texto: texto,
    p_media_estado: esMedia ? "pendiente" : null,
    p_enviado_en: saliente ? (recibido ?? new Date().toISOString()) : fecha(d.timestamp ?? raw.timestamp),
    p_evento_id: eventoId,
  });
  if (error) { console.error("wa_guardar_mensaje", error.message); return; }
  if (esMedia && id) await guardarMedia(id as number, tel, d);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok", { status: 200 });
  const esperado = await tokenValido();
  const recibido = req.headers.get("x-webhook-token") ?? "";
  if (!esperado || recibido !== esperado) {
    return Response.json({ ok: false, error: "no autorizado" }, { status: 401 });
  }
  const texto = await req.text();
  // deno-lint-ignore no-explicit-any
  let payload: any;
  try {
    payload = JSON.parse(texto);
  } catch {
    payload = { raw: texto };
  }

  if (payload?.reprocesar === true) {
    const { data: hechos } = await sb.from("wa_mensajes").select("evento_id").not("evento_id", "is", null);
    const ya = new Set((hechos ?? []).map((r) => r.evento_id));
    const { data: evs } = await sb.from("wa_eventos").select("id, payload, recibido_en").order("id");
    let n = 0;
    for (const e of evs ?? []) {
      if (ya.has(e.id)) continue;
      await procesar(e.id, e.payload, e.recibido_en);
      n++;
    }
    return Response.json({ ok: true, reprocesados: n });
  }

  const { data: fila, error } = await sb.from("wa_eventos").insert({ payload }).select("id").single();
  if (error) {
    console.error("insert wa_eventos", error.message);
    return Response.json({ ok: false }, { status: 500 });
  }
  // Responder rápido a BuilderBot; el resto sigue en segundo plano.
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  const tarea = procesar(fila.id, payload).catch((e) => console.error("procesar", (e as Error).message));
  if (rt?.waitUntil) rt.waitUntil(tarea); else await tarea;
  return Response.json({ ok: true });
});

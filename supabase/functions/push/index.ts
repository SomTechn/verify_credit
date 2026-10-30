// VerifyCredit · notificaciones push.
// - POST desde el trigger de la base (cabecera x-vc-secreto): decide a quién avisar y envía el push.
// - POST { clave:true }: devuelve la clave pública VAPID (la crea la primera vez).
// - POST { prueba:true } con la sesión del usuario: envía un aviso de prueba a sus dispositivos.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const TIPO: Record<string, string> = { nuevo: 'Nuevo', reingreso: 'Reingreso', refinanciamiento: 'Refinanciamiento', reestructuracion: 'Reestructuración', cambio_modalidad: 'Cambio de modalidad' };
const EST: Record<string, string> = { borrador: 'Borrador', en_analisis: 'En análisis', aprobada: 'Aprobada', denegada: 'Denegada',
  por_verificar: 'Por verificar', desembolso_pendiente: 'Desembolso pendiente', desembolsada: 'Desembolsada', rechazada_verificacion: 'Rechazada en verificación', desistida: 'Desistida' };

let cfg: Record<string, string> | null = null;
async function config() {
  if (cfg) return cfg;
  const { data, error } = await sb.rpc('push_config_get'); if (error) throw error;
  let c = (data || {}) as Record<string, string>;
  if (!c.publica || !c.privada) {
    const k = webpush.generateVAPIDKeys();
    const r = await sb.rpc('push_config_init', { p_publica: k.publicKey, p_privada: k.privateKey }); if (r.error) throw r.error;
    c = r.data as Record<string, string>;
  }
  webpush.setVapidDetails('https://edmvfqelxsxevpmxgbav.supabase.co', c.publica, c.privada);
  return (cfg = c);
}

async function enviar(ids: string[], msg: { title: string; body: string; id?: number; k?: string; voz?: string }) {
  ids = [...new Set(ids.filter(Boolean))];
  if (!ids.length) return 0;
  await config();
  const { data: subs, error } = await sb.from('push_subs').select('*').in('user_id', ids);
  if (error) throw error;
  const payload = JSON.stringify({ ...msg, tag: msg.k || (msg.id ? 'vc-' + msg.id : 'vc') });
  let ok = 0;
  await Promise.all((subs || []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: 'high' });
      ok++;
    } catch (e) {
      const st = (e as { statusCode?: number }).statusCode;
      if (st === 404 || st === 410) await sb.from('push_subs').delete().eq('endpoint', s.endpoint);   // dispositivo dado de baja
      else console.error('push', st, (e as Error).message);
    }
  }));
  return ok;
}

async function evento(ev: Record<string, any>) {
  const { data: perf } = await sb.from('perfiles').select('id, rol').eq('activo', true);
  const por = (...r: string[]) => (perf || []).filter((p) => r.includes(p.rol)).map((p) => p.id as string);
  const admins = por('admin'), analistas = por('analista', 'admin');
  const sin = (ids: string[]) => ids.filter((id) => id && id !== ev.actor);   // quien hizo el cambio no recibe su propio aviso
  let sol = ev;
  if (ev.tabla === 'meta') {   // meta diaria alcanzada: se avisa a todo el equipo
    const L = (n: number) => 'L ' + Math.round(n).toLocaleString('es-HN');
    return enviar((perf || []).map((p) => p.id as string), { title: '🎉 ¡Meta del día alcanzada!', body: `Colocado ${L(ev.monto)} de ${L(ev.meta)}. ¡Excelente trabajo, equipo!` });
  }
  if (ev.tabla === 'comentarios') {
    const { data } = await sb.from('solicitudes').select('id, codigo, nombre_cliente, asesor_id, analista_id, verificador_id').eq('id', ev.solicitud).maybeSingle();
    if (!data) return 0;
    const { data: au } = await sb.from('perfiles').select('nombre').eq('id', ev.autor).maybeSingle();
    return enviar(sin([data.asesor_id, data.analista_id, data.verificador_id, ...admins].filter((id) => id !== ev.autor)),
      { title: `💬 ${au?.nombre || 'Comentario'} en ${data.nombre_cliente}`, body: ev.texto || '', id: data.id });
  }
  const cli = `${sol.cliente} · ${TIPO[sol.tipo] || sol.tipo}${sol.codigo ? ' · ' + sol.codigo : ''}`;
  let t = '', ids: string[] = [];
  switch (sol.estado) {
    case 'en_analisis': t = sol.antes === 'borrador' || !sol.antes ? '📥 Nueva solicitud en análisis' : '📥 Solicitud en análisis'; ids = analistas; break;
    case 'aprobada': t = '✅ Solicitud aprobada'; ids = [sol.asesor]; break;
    case 'denegada': t = '❌ Solicitud denegada'; ids = [sol.asesor]; break;
    case 'borrador': t = '↩️ Solicitud devuelta para corregir'; ids = [sol.asesor]; break;
    case 'por_verificar': t = '🔎 Nueva verificación asignada'; ids = sol.verificador ? [sol.verificador] : por('verificador'); break;
    case 'desembolso_pendiente': t = '💸 Desembolso por transferencia pendiente'; ids = analistas; break;
    case 'desembolsada': t = '💰 Solicitud desembolsada'; ids = [sol.asesor]; break;
    case 'rechazada_verificacion': t = '⚠️ Rechazada en verificación'; ids = [sol.asesor, ...analistas]; break;
    case 'desistida': t = '🚫 Cliente desistió'; ids = [sol.asesor, ...analistas]; break;
    default: t = `Solicitud: ${EST[sol.estado] || sol.estado}`;
  }
  // El administrador se entera de todos los cambios
  return enviar(sin([...ids, ...admins]), { title: t, body: cli, id: sol.id });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const eco = new URL(req.url).searchParams.get('eco');   // prueba interna de envío (responde como un servicio push)
  if (eco) return new Response(null, { status: eco === 'baja' ? 410 : 201 });
  try {
    const body = await req.json().catch(() => ({}));
    const sec = req.headers.get('x-vc-secreto');
    if (sec) {
      const c = await config();
      if (sec !== c.secreto) return json({ error: 'secreto inválido' }, 401);
      return json({ enviados: await evento(body) });
    }
    if (body.clave) return json({ publica: (await config()).publica });
    if (body.aviso) {   // aviso personalizado escrito por el administrador
      const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
      const { data: u, error } = await sb.auth.getUser(jwt);
      if (error || !u?.user) return json({ error: 'Sesión no válida' }, 401);
      const { data: yo } = await sb.from('perfiles').select('rol, activo').eq('id', u.user.id).maybeSingle();
      if (!yo?.activo || yo.rol !== 'admin') return json({ error: 'Solo el administrador puede enviar avisos' }, 403);
      const a = body.aviso, msg = String(a.mensaje || '').trim().slice(0, 400), tit = String(a.titulo || 'Aviso del administrador').trim().slice(0, 60);
      if (!msg) return json({ error: 'Mensaje vacío' }, 400);
      const { data: act } = await sb.from('perfiles').select('id').eq('activo', true);
      const validos = new Set((act || []).map((p) => p.id as string));
      const ids = (Array.isArray(a.ids) ? a.ids : []).filter((id: string) => validos.has(id));
      const n = await enviar(ids, { title: '📢 ' + tit, body: msg, k: String(a.k || 'm' + Date.now()).slice(0, 40), voz: typeof a.voz === 'string' ? a.voz.slice(0, 500) : undefined });
      return json({ enviados: n, personas: ids.length });
    }
    if (body.prueba) {
      const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
      const { data: u, error } = await sb.auth.getUser(jwt);
      if (error || !u?.user) return json({ error: 'Sesión no válida' }, 401);
      const n = await enviar([u.user.id], { title: '🔔 Notificaciones activadas', body: 'Así le llegarán los avisos de VerifyCredit.' });
      return json({ enviados: n });
    }
    return json({ error: 'Solicitud no reconocida' }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});

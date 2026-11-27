# Motor de grabación de los tutoriales: graba la app real (dentro de un marco de navegador de PC o de celular)
# con un backend de demostración, guarda los cuadros (CDP screencast, JPEG 92) y una línea de tiempo con la
# narración, clics y teclas. compose.py arma luego el video final.
import json, os, time, base64, subprocess, hashlib, threading, http.server, functools
from playwright.sync_api import sync_playwright

WWW = '/home/claude/tuto/www'
OUT = '/home/claude/tuto/out'
TTS = '/home/claude/tuto/tts'
os.makedirs(TTS, exist_ok=True)
PORT = 8777
UA_MOVIL = 'Mozilla/5.0 (Linux; Android 14; 23078PND5G) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36'

_srv = None
def servidor():
    global _srv
    if _srv: return
    class H(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
    _srv = http.server.ThreadingHTTPServer(('127.0.0.1', PORT), functools.partial(H, directory=WWW))
    threading.Thread(target=_srv.serve_forever, daemon=True).start()

def tts(texto):
    """Genera la voz (pico, es-ES) y devuelve (ruta wav 44.1k mono, duración)."""
    h = hashlib.md5(texto.encode()).hexdigest()[:16]
    out = f'{TTS}/{h}.wav'
    if not os.path.exists(out):
        raw = f'{TTS}/{h}_raw.wav'
        subprocess.run(['pico2wave', '-l', 'es-ES', '-w', raw, texto], check=True)
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', raw, '-af', 'atempo=1.06,highpass=f=70,volume=1.6',
                        '-ar', '44100', '-ac', '1', out], check=True)
        os.remove(raw)
    d = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', out],
                             capture_output=True, text=True).stdout)
    return out, d

class Escena:
    """Una toma continua en PC (1280x720 @1.5 = 1920x1080) o en celular (390x844 @2)."""
    def __init__(self, pw, demo, nombre, tipo='pc', titulo='', sesion=False, appmode=False):
        servidor()
        self.demo, self.nombre, self.tipo, self.titulo = demo, nombre, tipo, titulo
        self.dir = f'{OUT}/{nombre}'
        os.makedirs(self.dir, exist_ok=True)
        for f in os.listdir(self.dir): os.remove(f'{self.dir}/{f}')
        self.b = pw.chromium.launch(executable_path='/usr/bin/google-chrome', args=['--no-sandbox', '--force-color-profile=srgb', '--hide-scrollbars'])
        if tipo == 'pc':
            self.ctx = self.b.new_context(viewport=dict(width=1920, height=1080), device_scale_factor=1, service_workers='block',
                                          timezone_id='America/Tegucigalpa', locale='es-HN', color_scheme='light')
        else:
            self.ctx = self.b.new_context(viewport=dict(width=780, height=1688), device_scale_factor=1, is_mobile=False, has_touch=True,
                                          user_agent=UA_MOVIL, service_workers='block', timezone_id='America/Tegucigalpa', locale='es-HN', color_scheme='light')
        self.ctx.add_init_script("try{localStorage.setItem('vc_nov_visto','9999')}catch(e){}")
        if sesion:
            self.ctx.add_init_script("try{localStorage.setItem('sb-edmvfqelxsxevpmxgbav-auth-token', %s)}catch(e){}" % json.dumps(json.dumps(demo.session())))
        self.ctx.route('**/*', demo.handle)
        self.p = self.ctx.new_page()
        self.errores = []
        self.p.on('pageerror', lambda e: self.errores.append(str(e)))
        self.p.goto(f'http://127.0.0.1:{PORT}/shell_{"pc" if tipo == "pc" else "movil"}.html')
        self.p.wait_for_timeout(400)
        if sesion:
            self.p.evaluate('SHELL.cargar()' + ('; SHELL.' + ('modoApp()' if tipo == 'pc' else 'abrirApp()') if appmode else ''))
            self.app().locator('#main .mt-hdr, #main h2').first.wait_for(state='visible', timeout=20000)
            self.p.wait_for_timeout(1500)
        self.frames, self.eventos, self.n = [], [], 0
        self.cdp = self.ctx.new_cdp_session(self.p)
        self.cdp.on('Page.screencastFrame', self._frame)
        self.hasta = 0
        self.cx, self.cy = (960, 600) if tipo == 'pc' else (390, 1000)

    # ---------- captura ----------
    def _frame(self, e):
        self.n += 1
        f = f'{self.dir}/f{self.n:06d}.jpg'
        with open(f, 'wb') as fh: fh.write(base64.b64decode(e['data']))
        self.frames.append((e['metadata']['timestamp'], f))
        try: self.cdp.send('Page.screencastFrameAck', {'sessionId': e['sessionId']})
        except Exception: pass

    def iniciar(self):
        mw, mh = (1920, 1080) if self.tipo == 'pc' else (780, 1688)
        self.cdp.send('Page.startScreencast', {'format': 'jpeg', 'quality': 92, 'maxWidth': mw, 'maxHeight': mh, 'everyNthFrame': 1})
        self.p.wait_for_timeout(300)
        self.t0 = time.time()
        # fuerza un cuadro inicial
        self.p.evaluate("document.body.style.outline='0px solid transparent'; requestAnimationFrame(()=>document.body.style.outline='')")
        self.p.wait_for_timeout(150)

    def terminar(self, cola=0.6):
        self.esperar()
        self.p.wait_for_timeout(int(cola * 1000))
        self.t1 = time.time()
        self.cdp.send('Page.stopScreencast')
        self.p.wait_for_timeout(200)
        meta = dict(nombre=self.nombre, tipo=self.tipo, titulo=self.titulo, t0=self.t0, t1=self.t1,
                    frames=[(t - self.t0, f) for t, f in sorted(self.frames)], eventos=[(t - self.t0, k, d) for t, k, d in self.eventos],
                    errores=self.errores)
        json.dump(meta, open(f'{self.dir}/meta.json', 'w'), ensure_ascii=False)
        self.b.close()
        return meta

    # ---------- tiempo ----------
    def ev(self, k, d=None): self.eventos.append((time.time(), k, d))
    def pausa(self, s): self.p.wait_for_timeout(int(s * 1000))
    def esperar(self):
        r = self.hasta - time.time()
        if r > 0: self.p.wait_for_timeout(int(r * 1000))

    def decir(self, cap, voz=None, extra=0.35):
        """Empieza la narración ahora (después de que termine la anterior). Las acciones siguientes ocurren mientras habla."""
        self.esperar()
        w, d = tts(voz or cap)
        self.ev('voz', dict(cap=cap, wav=w, dur=d))
        self.hasta = time.time() + d + extra
        return d

    # ---------- elementos ----------
    def app(self):
        return self.p.frame_locator('#frame')

    def caja(self, sel, en_app=True, n=0):
        """Centro del elemento en píxeles de la pantalla grabada (el marco tiene zoom)."""
        loc = (self.app().locator(sel) if en_app else self.p.locator(sel)).nth(n)
        try: loc.wait_for(state='visible', timeout=15000)
        except Exception:
            self.p.screenshot(path=f'{self.dir}/ERROR.png'); print('NO VISIBLE:', sel, flush=True); raise
        try: loc.scroll_into_view_if_needed(timeout=3000)
        except Exception: pass
        if en_app:
            # que no quede debajo del encabezado fijo ni de la barra de abajo
            tapado = loc.evaluate("e => { const b = e.getBoundingClientRect(); if (e.closest('.dlg-wrap, .rd-wrap')) return false; if (e.closest('.nv-vista')) return b.top < 90 || b.bottom > innerHeight - 20; return b.top < 110 || b.bottom > innerHeight - 90; }")
            if tapado:
                loc.evaluate("e => e.scrollIntoView({behavior:'smooth', block:'center'})"); self.p.wait_for_timeout(700)
        self.p.wait_for_timeout(120)
        r = loc.evaluate("e => { const b = e.getBoundingClientRect(); return [b.x, b.y, b.width, b.height]; }")
        if en_app:
            Z = 1.5 if self.tipo == 'pc' else 2
            fx, fy = self.p.evaluate("(() => { const b = document.querySelector('#frame').getBoundingClientRect(); return [b.x, b.y]; })()")
            r = [fx + r[0] * Z, fy + r[1] * Z, r[2] * Z, r[3] * Z]
        b = dict(x=r[0], y=r[1], width=r[2], height=r[3])
        return r[0] + r[2] / 2, r[1] + r[3] / 2, b

    def mover(self, x, y, ms=550):
        if self.tipo == 'pc':
            self.p.evaluate(f'SHELL.cursor({x},{y},{ms})')
        self.cx, self.cy = x, y

    def tocar(self, sel, en_app=True, n=0, dx=0, dy=0, pre=250):
        x, y, b = self.caja(sel, en_app, n)
        x += dx; y += dy
        if self.tipo == 'pc':
            self.mover(x + 6, y + 9)
            self.p.wait_for_timeout(pre + 450)
            self.p.evaluate(f'SHELL.ripple({x},{y})')
            self.ev('clic')
            self.p.mouse.click(x, y)
        else:
            self.p.evaluate(f'SHELL.dot({x},{y},true)')
            self.p.wait_for_timeout(pre + 200)
            self.p.evaluate(f'SHELL.tap({x},{y}); SHELL.dot(null,null,false)')
            self.ev('clic')
            self.p.touchscreen.tap(x, y)
        self.p.wait_for_timeout(250)

    def escribir(self, sel, texto, en_app=True, retardo=70, tocar=True, limpiar=False):
        if tocar: self.tocar(sel, en_app)
        if limpiar:
            self.p.keyboard.press('Control+A'); self.p.keyboard.press('Backspace')
        for ch in texto:
            self.p.keyboard.type(ch)
            self.ev('tecla')
            self.p.wait_for_timeout(retardo)
        self.p.wait_for_timeout(200)

    def llenar(self, sel, valor):
        """Para campos de fecha/hora: toca el campo y pone el valor."""
        self.tocar(sel)
        self.app().locator(sel).fill(valor)
        self.ev('tecla'); self.p.wait_for_timeout(500)

    def tecla(self, k):
        self.ev('tecla'); self.p.keyboard.press(k)

    def ver(self, sel, en_app=True, n=0, bloque='center'):
        """Desplaza suavemente hasta el elemento."""
        loc = (self.app().locator(sel) if en_app else self.p.locator(sel)).nth(n)
        loc.wait_for(state='attached', timeout=15000)
        loc.evaluate(f"e => e.scrollIntoView({{behavior:'smooth', block:'{bloque}'}})")
        self.p.wait_for_timeout(900)

    def señalar(self, sel, en_app=True, n=0):
        """Lleva el cursor (o el dedo) a un elemento sin tocarlo."""
        x, y, b = self.caja(sel, en_app, n)
        if self.tipo == 'pc':
            self.mover(x + 6, y + 9, 650)
        else:
            self.p.evaluate(f'SHELL.dot({x},{y},true)')
        self.p.wait_for_timeout(700)

    def soltar(self):
        if self.tipo != 'pc': self.p.evaluate('SHELL.dot(null,null,false)')

    def js(self, code):
        return self.p.evaluate(code)

    def app_js(self, code):
        return self.p.frames[1].evaluate(code) if len(self.p.frames) > 1 else None

class Tarjeta:
    """Placa de título (imagen fija) con narración."""
    def __init__(self, nombre, titulo, sub='', lineas=None):
        self.nombre, self.titulo, self.sub = nombre, titulo, sub
        self.lineas = lineas or []

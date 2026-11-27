# Arma el video final: una pieza por escena (PC a pantalla completa, celular dentro de un teléfono con el texto al lado,
# placas de título), subtítulos quemados, y una pista de audio con voz, clics, teclas y música suave.
import json, os, subprocess, wave, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from engine import tts, OUT

W, H, FPS, SR = 1920, 1080, 30, 44100
FONT = '/usr/share/fonts/opentype/inter/Inter-SemiBold.otf'
FONT_B = '/usr/share/fonts/opentype/inter/Inter-Bold.otf'
FONT_R = '/usr/share/fonts/opentype/inter/Inter-Regular.otf'
ICON = '/home/claude/tuto/www/icon-512.png'
ENC = ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-r', str(FPS)]
# Teléfono en las escenas de celular
PH_W, PH_H = 462, 1000
PH_X, PH_Y = 280, 40

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError(r.stderr[-3000:])

def fuente(p, s): return ImageFont.truetype(p, s)

def fondo(draw_img):
    g = np.zeros((H, W, 3), np.float32)
    y = np.linspace(0, 1, H)[:, None]; x = np.linspace(0, 1, W)[None, :]
    a = np.array([10, 42, 102], np.float32); b = np.array([24, 119, 242], np.float32)
    t = np.clip(0.65 * x + 0.35 * y, 0, 1)[..., None]
    g = a * (1 - t) + b * t
    return Image.fromarray(g.astype(np.uint8))

def envolver(d, texto, f, ancho):
    pal, lineas, cur = texto.split(), [], ''
    for p in pal:
        t = (cur + ' ' + p).strip()
        if d.textlength(t, font=f) <= ancho: cur = t
        else: lineas.append(cur); cur = p
    if cur: lineas.append(cur)
    return lineas

def placa(path, titulo, sub='', etiqueta='Tutorial · VerifyCredit'):
    im = fondo(None); d = ImageDraw.Draw(im)
    ic = Image.open(ICON).convert('RGBA').resize((150, 150), Image.LANCZOS)
    m = Image.new('L', (150, 150), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, 149, 149), 34, fill=255)
    im.paste(ic, (160, 250), m)
    d.text((160, 440), etiqueta.upper(), font=fuente(FONT_B, 30), fill=(170, 205, 255))
    y = 500
    for ln in envolver(d, titulo, fuente(FONT_B, 92), 1550):
        d.text((160, y), ln, font=fuente(FONT_B, 92), fill='white'); y += 110
    if sub:
        for ln in envolver(d, sub, fuente(FONT_R, 40), 1500):
            d.text((162, y + 18), ln, font=fuente(FONT_R, 40), fill=(215, 230, 255)); y += 54
    im.save(path)

def fondo_movil(path, titulo):
    im = fondo(None); d = ImageDraw.Draw(im)
    # sombra y cuerpo del teléfono
    sh = Image.new('RGBA', (W, H), (0, 0, 0, 0)); ds = ImageDraw.Draw(sh)
    ds.rounded_rectangle((PH_X - 22, PH_Y - 22 + 16, PH_X + PH_W + 22, PH_Y + PH_H + 22 + 16), 64, fill=(0, 0, 0, 120))
    sh = sh.filter(ImageFilter.GaussianBlur(18)); im.paste(sh, (0, 0), sh)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((PH_X - 18, PH_Y - 18, PH_X + PH_W + 18, PH_Y + PH_H + 18), 60, fill=(18, 20, 26))
    d.rounded_rectangle((PH_X - 2, PH_Y - 2, PH_X + PH_W + 2, PH_Y + PH_H + 2), 44, fill=(40, 44, 52))
    d.text((900, 120), 'EN EL CELULAR', font=fuente(FONT_B, 30), fill=(170, 205, 255))
    y = 165
    for ln in envolver(d, titulo, fuente(FONT_B, 58), 900):
        d.text((900, y), ln, font=fuente(FONT_B, 58), fill='white'); y += 70
    im.save(path)
    # esquinas redondeadas de la pantalla: capa con el color del marco fuera del rectángulo redondeado
    co = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    mk = Image.new('L', (PH_W, PH_H), 255); ImageDraw.Draw(mk).rounded_rectangle((0, 0, PH_W - 1, PH_H - 1), 42, fill=0)
    co.paste(Image.new('RGBA', (PH_W, PH_H), (40, 44, 52, 255)), (PH_X, PH_Y), mk)
    co.save(path.replace('.png', '_esq.png'))

def ass_t(s):
    s = max(0, s); h = int(s // 3600); m = int(s % 3600 // 60); return f'{h}:{m:02d}:{s % 60:05.2f}'

def subtitulos(path, voces, estilo):
    cab = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {W}
PlayResY: {H}
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Pc,Inter SemiBold,42,&H00FFFFFF,&H000000FF,&H38101826,&H38101826,0,0,0,0,100,100,0,0,3,16,0,2,220,220,44,1
Style: Movil,Inter SemiBold,50,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,4,900,110,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    with open(path, 'w', encoding='utf-8') as f:
        f.write(cab)
        for t, d in voces:
            txt = d['cap'].replace('\n', ' ')
            f.write(f"Dialogue: 0,{ass_t(t)},{ass_t(t + d['dur'] + 0.25)},{estilo},,0,0,0,,{txt}\n")

def lista_cuadros(meta, path):
    fr = meta['frames']; D = meta['t1'] - meta['t0']
    if not fr: raise RuntimeError('escena sin cuadros: ' + meta['nombre'])
    # el último cuadro anterior al inicio cuenta como el primero
    ini = [x for x in fr if x[0] <= 0]
    fr = ([(0.0, ini[-1][1])] if ini else [(0.0, fr[0][1])]) + [x for x in fr if x[0] > 0]
    with open(path, 'w') as f:
        for i, (t, p) in enumerate(fr):
            nt = fr[i + 1][0] if i + 1 < len(fr) else D
            f.write(f"file '{p}'\nduration {max(nt - t, 0.001):.4f}\n")
        f.write(f"file '{fr[-1][1]}'\n")
    return D

def pieza_escena(meta, dst):
    d = f"{OUT}/{meta['nombre']}"
    D = lista_cuadros(meta, f'{d}/list.txt')
    voces = [(t, x) for t, k, x in meta['eventos'] if k == 'voz']
    ass = f'{d}/subs.ass'
    subtitulos(ass, voces, 'Pc' if meta['tipo'] == 'pc' else 'Movil')
    fade = f"fade=t=in:st=0:d=0.3,fade=t=out:st={max(D - 0.35, 0):.2f}:d=0.35"
    tmp = dst.replace('.mp4', '.tmp.mp4')
    if meta['tipo'] == 'pc':
        run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', f'{d}/list.txt',
             '-vf', f'scale={W}:{H}:flags=lanczos,setsar=1,fps={FPS},subtitles={ass},{fade},format=yuv420p', '-t', f'{D:.3f}', *ENC, '-an', tmp])
    else:
        bg = f'{d}/bg.png'; fondo_movil(bg, meta.get('titulo') or '')
        fc = (f"[0:v]scale={PH_W}:{PH_H}:flags=lanczos,setsar=1,fps={FPS}[ph];[1:v]loop=-1:1:0,fps={FPS},setsar=1[bg];[2:v]loop=-1:1:0,fps={FPS},format=rgba[es];"
              f"[bg][ph]overlay={PH_X}:{PH_Y}:shortest=1[a];[a][es]overlay=0:0:shortest=1,subtitles={ass},{fade},format=yuv420p[v]")
        run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', f'{d}/list.txt', '-i', bg, '-i', bg.replace('.png', '_esq.png'),
             '-filter_complex', fc, '-map', '[v]', '-t', f'{D:.3f}', *ENC, '-an', tmp])
    os.replace(tmp, dst)
    return D, meta['eventos']

def pieza_placa(item, dst):
    png = f"{OUT}/{item['nombre']}.png"
    placa(png, item['titulo'], item.get('sub', ''), item.get('etiqueta', 'Tutorial · VerifyCredit'))
    t, evs = 0.8, []
    for cap, voz in item.get('lineas', []):
        w, dur = tts(voz or cap); evs.append((t, 'voz', dict(cap=cap, wav=w, dur=dur))); t += dur + 0.35
    D = max(t + 0.7, item.get('min', 3.5))
    ass = f"{OUT}/{item['nombre']}.ass"
    subtitulos(ass, [(a, c) for a, k, c in evs], 'Pc') if item.get('subs', False) else open(ass, 'w').write(
        '[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Pc,Inter,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,0,0,0,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n')
    tmp = dst.replace('.mp4', '.tmp.mp4')
    run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', str(FPS), '-i', png, '-vf',
         f'format=yuv420p,loop=-1:1,trim=duration={D:.3f},subtitles={ass},fade=t=in:st=0:d=0.4,fade=t=out:st={D - 0.4:.2f}:d=0.4,format=yuv420p', *ENC, '-an', tmp])
    os.replace(tmp, dst)
    return D, evs

# ---------- sonido ----------
def leer_wav(p):
    with wave.open(p) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
        if w.getnchannels() == 2: a = a.reshape(-1, 2).mean(1)
    return a

def clic(fuerte=1.0):
    n = int(SR * 0.03); t = np.arange(n) / SR
    rng = np.random.default_rng(1)
    s = rng.normal(0, 1, n) * np.exp(-t * 260) * 0.35 + np.sin(2 * np.pi * 2100 * t) * np.exp(-t * 400) * 0.25
    return (s * fuerte).astype(np.float32)

def tecla():
    n = int(SR * 0.018); t = np.arange(n) / SR
    rng = np.random.default_rng(2)
    return (rng.normal(0, 1, n) * np.exp(-t * 420) * 0.12).astype(np.float32)

def musica(D):
    n = int(D * SR); t = np.arange(n) / SR; out = np.zeros(n, np.float32)
    # acordes suaves (I–vi–IV–V en Do), 4 s cada uno
    acordes = [[261.63, 329.63, 392.00], [220.00, 261.63, 329.63], [174.61, 220.00, 261.63], [196.00, 246.94, 293.66]]
    L = 4.0
    for i in range(int(D / L) + 1):
        a0 = int(i * L * SR); a1 = min(n, int((i + 1) * L * SR + 0.8 * SR))
        if a0 >= n: break
        tt = np.arange(a1 - a0) / SR
        env = np.minimum(1, tt / 0.9) * np.minimum(1, np.maximum(0, (L + 0.8 - tt) / 1.0))
        for f in acordes[i % 4]:
            for k, g in ((1, 1.0), (2, 0.25), (0.5, 0.35)):
                out[a0:a1] += (np.sin(2 * np.pi * f * k * tt + k) * g * env).astype(np.float32)
        # campanita suave al inicio de cada acorde
        bell = np.sin(2 * np.pi * acordes[i % 4][2] * 2 * tt) * np.exp(-tt * 3) * 0.6
        out[a0:a1] += bell.astype(np.float32)
    out /= np.max(np.abs(out)) + 1e-9
    return out

def audio(D, eventos, dst):
    n = int((D + 0.5) * SR); voz = np.zeros(n, np.float32); fx = np.zeros(n, np.float32)
    c, k = clic(), tecla()
    for t, tipo, d in eventos:
        i = int(t * SR)
        if i >= n: continue
        if tipo == 'voz':
            a = leer_wav(d['wav']); j = min(n, i + len(a)); voz[i:j] += a[:j - i]
        elif tipo == 'clic':
            j = min(n, i + len(c)); fx[i:j] += c[:j - i]
        elif tipo == 'tecla':
            j = min(n, i + len(k)); fx[i:j] += k[:j - i]
    # música con atenuación bajo la voz
    m = musica(D + 0.5)
    act = (np.abs(voz) > 0.01).astype(np.float32)
    ker = np.ones(int(0.35 * SR), np.float32) / int(0.35 * SR)
    act = np.clip(np.convolve(act, ker, 'same') * 3, 0, 1)
    gm = 0.10 - 0.055 * act
    fade = np.minimum(1, np.arange(n) / (1.5 * SR)) * np.minimum(1, (n - np.arange(n)) / (2.0 * SR))
    mix = voz * 0.95 + fx * 0.8 + m * gm * fade
    mix /= max(1.0, np.max(np.abs(mix)) / 0.89)
    with wave.open(dst, 'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((mix * 32767).astype(np.int16).tobytes())

def armar(items, salida):
    """items: lista de dicts {'placa': {...}} o {'escena': 'nombre'}. Devuelve duración."""
    piezas, evs, T = [], [], 0.0
    for i, it in enumerate(items):
        dst = f"{OUT}/pieza_{os.path.basename(salida)}_{i:02d}.mp4"
        if 'placa' in it: D, e = pieza_placa(it['placa'], dst)
        else:
            meta = json.load(open(f"{OUT}/{it['escena']}/meta.json"))
            D, e = pieza_escena(meta, dst)
        # duración real del archivo (por redondeo de cuadros)
        D = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', dst], capture_output=True, text=True).stdout)
        evs += [(T + t, k, d) for t, k, d in e]
        piezas.append(dst); T += D
        print(f'  pieza {i}: {D:.1f}s', flush=True)
    lst = f'{OUT}/concat_{os.path.basename(salida)}.txt'
    open(lst, 'w').write(''.join(f"file '{p}'\n" for p in piezas))
    vid = f'{OUT}/v_{os.path.basename(salida)}'
    run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', lst, '-c', 'copy', vid])
    wav = f'{OUT}/a_{os.path.basename(salida)}.wav'
    audio(T, evs, wav)
    tmp = salida.replace('.mp4', '.tmp.mp4')
    run(['ffmpeg', '-y', '-loglevel', 'error', '-i', vid, '-i', wav, '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k',
         '-shortest', '-movflags', '+faststart', tmp])
    os.replace(tmp, salida)
    return T

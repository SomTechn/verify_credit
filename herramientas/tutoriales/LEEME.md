# Motor de los tutoriales en video (27-nov-2026)

Graba la app real (index.html) dentro de un marco de navegador de PC (shell_pc.html) o de celular Android (shell_movil.html),
con un backend de demostración en memoria (backend.py, datos inventados). Voz: pico2wave es-ES; música, clics y subtítulos generados.

Requisitos: python3 con playwright, numpy y pillow; ffmpeg; pico2wave (apt libttspico-utils); google-chrome; fuente Inter.
Preparar `www/`: copiar index.html, manifest.json, íconos, y en `www/lib/` supabase.js (UMD), xlsx.full.min.js, html2canvas.min.js y jspdf.umd.min.js.
Rutas en engine.py y compose.py apuntan a /home/claude/tuto: ajustarlas.

    python3 v1.py   # ingresar e instalar
    python3 v2.py   # refinanciamiento
    python3 v3.py   # Cámbiate a nivelado

Cada script graba sus escenas (pc y mov) y arma el MP4 1920x1080 en out/. `python3 v3.py pc` regraba solo la escena de PC.

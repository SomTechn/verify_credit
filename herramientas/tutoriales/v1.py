# Video 1: cómo ingresar a VerifyCredit e instalar la app (PC y celular)
import sys
from playwright.sync_api import sync_playwright
from engine import Escena
from backend import Demo
from compose import armar

VC = 'verifai crédit'
URLV = 'verifai crédit, punto vércel, punto app'
demo = Demo()
solo = sys.argv[1:]  # opcional: grabar solo algunas escenas

with sync_playwright() as pw:
    if not solo or 'pc' in solo:
        demo.reset()
        e = Escena(pw, demo, 'v1_pc', 'pc'); e.iniciar()
        e.decir('Abra Google Chrome en su computadora. En la barra de direcciones escriba verifycredit.vercel.app y presione Enter.',
                f'Abra Google Chrome en su computadora. En la barra de direcciones escriba: {URLV}. Y presione Enter.')
        e.pausa(3.2)
        e.escribir('#url', 'verifycredit.vercel.app', en_app=False, retardo=65)
        e.tecla('Enter'); e.pausa(1.2)
        e.decir('Escriba el correo y la contraseña que le entregó el administrador.')
        e.escribir('#lEmail', 'carlos.mejia@maspisto.hn', retardo=45)
        e.escribir('#lPass', 'Mp2026*', retardo=90)
        e.decir('Luego toque Entrar.')
        e.tocar('#fLogin button[type=submit]')
        e.pausa(1.5)
        e.decir('Ya está adentro. Esta es su pantalla de inicio, Mi cartera, con las solicitudes de sus clientes y el paso en que va cada una.')
        e.señalar('.mt-hdr h2'); e.pausa(1.6)
        e.señalar('.gs-c', n=0)
        e.decir('En el menú de la izquierda tiene Mi cartera y Cámbiate a nivelado. El número rojo indica cuántas llamadas tiene programadas para hoy.')
        e.señalar('#sideNav [data-nk="gestor"]'); e.pausa(1.8)
        e.señalar('#sideNav [data-nk="nivelado"]')
        e.decir('Abajo están las Novedades del sistema y el botón Salir, para cerrar su sesión cuando termine.')
        e.señalar('#sideNav [data-hb="btnNov"]'); e.pausa(1.6)
        e.señalar('#sideNav [data-hb="btnOut"]')
        e.decir('Para instalar la aplicación en la computadora, toque el ícono de instalar que aparece a la derecha de la barra de direcciones.')
        e.pausa(2.5)
        e.tocar('#instIco', en_app=False)
        e.js('SHELL.instalar(true)')
        e.decir('Y luego toque Instalar.')
        e.tocar('#instOk', en_app=False)
        e.js('SHELL.modoApp()')
        e.decir('Listo. VerifyCredit se abre en su propia ventana, como cualquier programa.')
        e.pausa(1)
        e.mover(1500, 700, 700)
        e.decir('Y queda un acceso directo en el escritorio. Los demás días, solo dele doble clic al ícono para entrar.')
        e.js('SHELL.escritorio(true)'); e.pausa(1.2)
        e.tocar('#deskApp', en_app=False)
        e.pausa(0.15); e.ev('clic')
        e.pausa(0.5)
        e.js('SHELL.escritorio(false)')
        e.terminar(1.0)

    if not solo or 'mov' in solo:
        demo.reset()
        e = Escena(pw, demo, 'v1_mov', 'movil', 'Entrar e instalar la app en el celular'); e.iniciar()
        e.decir('En el celular, abra Chrome y escriba la misma dirección: verifycredit.vercel.app.', f'En el celular, abra Chrome y escriba la misma dirección: {URLV}.')
        e.pausa(1.5)
        e.escribir('#url', 'verifycredit.vercel.app', en_app=False, retardo=65)
        e.tecla('Enter'); e.pausa(1)
        e.decir('Para instalar la aplicación, toque Instalar la app en este teléfono. Ahí le aparecen los pasos.')
        e.pausa(2.2)
        e.tocar('#btnInstallLogin')
        e.decir('Léalos y toque Entendido.')
        e.pausa(1.2)
        e.tocar('.dlg-wrap .btn.pri')
        e.decir('Ahora toque los tres puntos de Chrome, arriba a la derecha.')
        e.pausa(1.5)
        e.tocar('#menuBtn', en_app=False)
        e.js('SHELL.menu(true)')
        e.decir('Elija Instalar aplicación.')
        e.pausa(0.6)
        e.tocar('#mInst', en_app=False)
        e.js('SHELL.resaltar(true)'); e.pausa(0.4); e.js('SHELL.hoja(true)')
        e.decir('Y confírmelo tocando Instalar.')
        e.pausa(0.8)
        e.tocar('#shOk', en_app=False)
        e.js('SHELL.inicio(true)')
        e.decir('El ícono de VerifyCredit queda en la pantalla de su celular. Tóquelo para abrir la aplicación.', f'El ícono de {VC} queda en la pantalla de su celular. Tóquelo para abrir la aplicación.')
        e.pausa(2.6)
        e.tocar('#homeApp', en_app=False)
        e.js('SHELL.abrirApp()')
        e.decir('Se abre a pantalla completa, sin la barra del navegador. Ingrese con su correo y su contraseña.')
        e.pausa(2.4)
        e.escribir('#lEmail', 'carlos.mejia@maspisto.hn', retardo=45)
        e.escribir('#lPass', 'Mp2026*', retardo=90)
        e.tocar('#fLogin button[type=submit]')
        e.pausa(1.5)
        e.decir('En el celular, el menú está abajo: Mi cartera y Nivelado.')
        e.señalar('#botNav [data-nk="gestor"]'); e.pausa(1.2)
        e.señalar('#botNav [data-nk="nivelado"]'); e.soltar()
        e.decir('En Más encuentra las Novedades y el botón Salir.')
        e.tocar('#botNav [data-mas]')
        e.pausa(2.5)
        e.tocar('.dlg-wrap .btn.ghost')
        e.terminar(1.0)

armar([
    {'placa': dict(nombre='v1_ini', titulo='Cómo ingresar a VerifyCredit e instalar la app', sub='Tutorial para gestores de cobro · 1 de 3',
                   lineas=[('', f'En este video aprenderá a entrar a {VC} desde la computadora y desde el celular, y a instalar la aplicación.')], min=4)},
    {'escena': 'v1_pc'},
    {'escena': 'v1_mov'},
    {'placa': dict(nombre='v1_ios', titulo='¿Tiene iPhone?', sub='Abra verifycredit.vercel.app en Safari, toque el botón Compartir y elija «Agregar a pantalla de inicio».', etiqueta='Instalar en iPhone',
                   lineas=[('', f'Si tiene iPhone, abra la dirección en Safari, toque el botón Compartir y elija: Agregar a pantalla de inicio.')], min=4)},
    {'placa': dict(nombre='v1_fin', titulo='¡Listo!', sub='Si olvida su contraseña, pídale al administrador que se la cambie. Siguiente video: solicitudes de refinanciamiento.', etiqueta='Tutorial · VerifyCredit',
                   lineas=[('', 'Si olvida su contraseña, pídale al administrador que se la cambie. En el siguiente video verá cómo registrar solicitudes de refinanciamiento.')], min=4)},
], '/home/claude/tuto/out/tutorial_1_ingresar_instalar.mp4')
print('listo')

# Video 2: cómo registrar una solicitud de refinanciamiento (o reingreso) y darle seguimiento (PC y celular)
import sys
from playwright.sync_api import sync_playwright
from engine import Escena
from backend import Demo
from compose import armar

demo = Demo()
solo = sys.argv[1:]

with sync_playwright() as pw:
    if not solo or 'pc' in solo:
        demo.reset()
        e = Escena(pw, demo, 'v2_pc', 'pc', sesion=True, appmode=True); e.iniciar()
        e.decir('Para registrar una solicitud, entre a Mi cartera y toque Nueva solicitud.')
        e.pausa(1.8)
        e.tocar('#sideNav [data-nueva]')
        e.decir('Escriba el número de identidad del cliente. Si ya tuvo préstamos con nosotros, el sistema lo encuentra y llena sus datos solo.')
        e.pausa(1.0)
        e.escribir('#nDni', '0501198803214', retardo=85)
        e.pausa(1.0)
        e.decir('Aquí ve su última solicitud. Revise el tipo: Refinanciamiento, si todavía tiene su préstamo vigente; o Reingreso, si ya lo terminó de pagar.')
        e.señalar('#nEnc'); e.pausa(2.5)
        e.señalar('#nTipo button[data-v="refinanciamiento"]'); e.pausa(1.5)
        e.señalar('#nTipo button[data-v="reingreso"]')
        e.decir('La cartera ya viene marcada. Confirme el nombre completo y el teléfono.')
        e.señalar('#nCart [data-c="2"]'); e.pausa(1.2)
        e.señalar('#nNombre'); e.pausa(1.0)
        e.señalar('#nTel')
        e.decir('Si quiere, deje una nota para el asesor; por ejemplo, cuánto pide el cliente o a qué hora llamarlo.')
        e.pausa(1.5)
        e.escribir('#nNota', 'Pide L 15,000. Llamarle después de las 4.', retardo=45)
        e.decir('Y toque Crear.')
        e.tocar('#nOk')
        e.pausa(1.2)
        e.decir('Listo. La solicitud le llega al asesor, que la revisa y la envía a análisis. Usted la ve aquí, en la lista En proceso.')
        e.señalar('.gs-c', n=0)
        e.decir('La barra le muestra en qué paso va: registrada, análisis, aprobada, verificación, desembolso y desembolsada.')
        e.señalar('.gs-c .gp', n=1)
        e.decir('Toque una solicitud para ver el detalle: el estado, el asesor que la tiene y desde cuándo está en ese paso.')
        e.pausa(1.2)
        e.tocar('.gs-c .mt-nm', n=1)
        e.pausa(3.0)
        e.tocar('.dlg-wrap .btn.pri')
        e.decir('Con estos botones puede llamar al cliente o escribirle por WhatsApp.')
        e.señalar('.gs-c .mt-acc a', n=0); e.pausa(1.0)
        e.señalar('.gs-c .mt-acc a', n=1)
        e.decir('Arriba puede ver las desembolsadas, las que se cerraron sin desembolso o todas.')
        e.tocar('[data-gv="desembolsadas"]'); e.pausa(1.6)
        e.tocar('[data-gv="proceso"]')
        e.decir('Y en el buscador encuentra cualquier solicitud por el nombre, el código o la identidad del cliente.')
        e.pausa(0.8)
        e.escribir('#gsQ', 'Karla', retardo=110)
        e.pausa(1.5)
        e.escribir('#gsQ', '', limpiar=True, tocar=False)
        e.terminar(1.0)

    if not solo or 'mov' in solo:
        demo.reset()
        e = Escena(pw, demo, 'v2_mov', 'movil', 'Registrar desde el celular', sesion=True, appmode=True); e.iniciar()
        e.decir('En el celular es igual. En Mi cartera, toque Nueva solicitud.')
        e.pausa(1.6)
        e.tocar('.mt-hdr [data-nueva]')
        e.decir('Escriba la identidad del cliente.')
        e.escribir('#nDni', '0501199107733', retardo=85)
        e.pausa(1.0)
        e.decir('Este cliente ya terminó de pagar su préstamo, así que elija Reingreso.')
        e.pausa(1.4)
        e.tocar('#nTipo button[data-v="reingreso"]')
        e.decir('Revise el nombre, el teléfono y la fecha de ingreso, y toque Crear.')
        e.ver('#nTel'); e.pausa(1.5)
        e.ver('#nIng'); e.pausa(1.0)
        e.tocar('#nOk')
        e.pausa(1.0)
        e.decir('Ya aparece en su lista, en el paso Registrada.')
        e.ver('.gs-c', n=0)
        e.decir('Si el cliente ya tiene una solicitud en proceso, el sistema no le deja registrar otra y le dice cuál es.')
        e.app_js("window.scrollTo({top:0, behavior:'smooth'})"); e.pausa(0.9)
        e.tocar('.mt-hdr [data-nueva]')
        e.escribir('#nDni', '0501198512006', retardo=70)
        e.pausa(2.0)
        e.decir('En ese caso, dele seguimiento a la que ya está abierta.')
        e.ver('#nEnc'); e.pausa(2.2)
        e.tocar('.dlg-wrap .btn.ghost')
        e.terminar(1.0)

armar([
    {'placa': dict(nombre='v2_ini', titulo='Cómo registrar una solicitud de refinanciamiento', sub='Tutorial para gestores de cobro · 2 de 3',
                   lineas=[('', 'En este video verá cómo registrar una solicitud de refinanciamiento o de reingreso para un cliente de su cartera, y cómo darle seguimiento.')], min=4)},
    {'escena': 'v2_pc'},
    {'escena': 'v2_mov'},
    {'placa': dict(nombre='v2_fin', titulo='¡Listo!', sub='Siguiente video: el proceso completo de Cámbiate a nivelado.', etiqueta='Tutorial · VerifyCredit',
                   lineas=[('', 'Así de fácil. En el siguiente video verá el proceso completo de la campaña Cámbiate a nivelado.')], min=4)},
], '/home/claude/tuto/out/tutorial_2_refinanciamiento.mp4')
print('listo')

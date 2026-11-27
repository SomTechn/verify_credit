# Backend de demostración en memoria para grabar los tutoriales sobre la app real (index.html).
# Responde las llamadas de supabase-js que usa el gestor de cobro. Todos los datos son inventados.
import json, base64, datetime, re, copy

WWW = '/home/claude/tuto/www'
GESTOR = '7a1b2c3d-0000-4000-8000-000000000001'
ASESOR = '7a1b2c3d-0000-4000-8000-000000000002'
PERF = {
    GESTOR: dict(id=GESTOR, nombre='Carlos Mejía', rol='gestor', activo=True, carteras=[2], roles_extra=[], email='carlos.mejia@maspisto.hn', creado_en='2026-11-01T00:00:00Z'),
    ASESOR: dict(id=ASESOR, nombre='Daniela Paz', rol='asesor', activo=True, carteras=[], roles_extra=[], email='daniela.paz@maspisto.hn', creado_en='2026-11-01T00:00:00Z'),
}
CART = [dict(id=2, nombre='Gestión Telefónica'), dict(id=3, nombre='Gestión Presencial'), dict(id=4, nombre='Gestión Telefónica #2')]
HOY = '2026-11-27'

def b64(o): return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip('=')

def iso(d, h='15:00:00'): return f'{d}T{h}Z'

class Demo:
    def __init__(self):
        self.reset()

    def reset(self):
        self.me = GESTOR
        self.logged = False
        self.next_sol = 4120
        # Clientes que existen en VerifyCredit (para buscar por identidad)
        self.clientes = {
            '0501198803214': dict(nombre='Andrea Sofía Castillo Rivera', telefono='9871-2045', fecha_ingreso='2021-03-15', cartera=2, codigo='CR-3871', tipo='nuevo', estado='desembolsada', fecha='2026-05-20', desembolsada='2026-05-22'),
            '0501199107733': dict(nombre='Luis Fernando Aguilar Paz', telefono='3345-8812', fecha_ingreso='2019-08-01', cartera=2, codigo='CR-3640', tipo='refinanciamiento', estado='desembolsada', fecha='2026-04-02', desembolsada='2026-04-03'),
            '0501198512006': dict(nombre='Karla Patricia Velásquez Amador', telefono='9452-1188', fecha_ingreso='2020-01-10', cartera=2, codigo='CR-4102', tipo='refinanciamiento', estado='en_analisis', fecha='2026-11-26', desembolsada=None, abierta=True),
            '0501199306541': dict(nombre='Marvin Josué Ortega Lanza', telefono='8821-4470', fecha_ingreso='2022-06-01', cartera=2, codigo='CR-3302', tipo='nuevo', estado='desembolsada', fecha='2025-10-12', desembolsada='2025-10-14'),
            '0501199002288': dict(nombre='Rosa Elena Fiallos Banegas', telefono='9663-0251', fecha_ingreso='2018-02-01', cartera=2, codigo='CR-3117', tipo='nuevo', estado='desembolsada', fecha='2025-07-08', desembolsada='2025-07-09'),
        }
        self.sols = [
            dict(id=4102, codigo='CR-4102', nombre_cliente='Karla Patricia Velásquez Amador', tipo='refinanciamiento', estado='en_analisis', cartera_id=2, dni='0501-1985-12006', telefono='9452-1188', creado_en=iso('2026-11-26','16:10:00'), estado_desde=iso('2026-11-27','14:20:00'), desembolsado_en=None, en_espera=False, analisis_tomado=True, es_mia=True, registro='Carlos Mejía', asesor='Daniela Paz'),
            dict(id=4096, codigo='CR-4096', nombre_cliente='Óscar Danilo Rápalo Cruz', tipo='reingreso', estado='aprobada', cartera_id=2, dni='0501-1987-04411', telefono='9780-3326', creado_en=iso('2026-11-25','15:00:00'), estado_desde=iso('2026-11-26','17:30:00'), desembolsado_en=None, en_espera=False, analisis_tomado=True, es_mia=True, registro='Carlos Mejía', asesor='Daniela Paz'),
            dict(id=4071, codigo='CR-4071', nombre_cliente='Gloria Esperanza Matute Díaz', tipo='refinanciamiento', estado='desembolsada', cartera_id=2, dni='0501-1979-09310', telefono='3190-7742', creado_en=iso('2026-11-20','14:00:00'), estado_desde=iso('2026-11-21','16:00:00'), desembolsado_en=iso('2026-11-21','16:00:00'), en_espera=False, analisis_tomado=True, es_mia=True, registro='Carlos Mejía', asesor='Daniela Paz'),
            dict(id=4055, codigo='CR-4055', nombre_cliente='Héctor Manuel Zavala Ruiz', tipo='refinanciamiento', estado='desembolsada', cartera_id=2, dni='0501-1983-02145', telefono='9541-6037', creado_en=iso('2026-11-14','15:30:00'), estado_desde=iso('2026-11-15','15:00:00'), desembolsado_en=iso('2026-11-15','15:00:00'), en_espera=False, analisis_tomado=True, es_mia=False, registro='Daniela Paz', asesor='Daniela Paz'),
        ]
        # Préstamos solo interés de la campaña (cartera del gestor)
        P = []
        def pr(i, nombre, tipo, fecha, cap, bal, cuo, mora, dia, tel=None, dni=None, res=None, seg=None, nota=None, gest=0, aplica='antiguedad', meses=14):
            P.append(dict(id=i, nombre=nombre, tipo=tipo, fecha=fecha, capital=cap, bal=bal, cuotas=cuo, mora=mora, total=round(bal+cuo+mora, 2), dia=dia,
                          cartera_id=2, cartera_txt='Gestión Telefónica', en_lista=True, salio_en=None, telefono=tel, dni=dni, resultado=res,
                          resultado_en=iso('2026-11-26','17:00:00') if res else None, resultado_por='Carlos Mejía' if res else None,
                          seguimiento_en=seg, nota=nota, monto_extra=None, gestiones=gest, aplica=aplica, meses=meses, sol=None))
        pr(501, 'Andrea Sofía Castillo Rivera', 'PREST. QUINCENAL', '2025-05-20', 20000, 20000, 1600, 0, 'Día 15', '9871-2045', None, meses=18)
        pr(502, 'Marvin Josué Ortega Lanza', 'PREST. QUINCENAL', '2025-10-12', 12000, 12000, 960, 0, 'Día 30', '8821-4470', None, aplica='antiguedad', meses=13)
        pr(503, 'Rosa Elena Fiallos Banegas', 'PREST. MENSUAL', '2025-07-08', 15000, 11200, 2240, 0, 'Día 30', '9663-0251', None, res='volver_llamar', seg=iso('2026-11-27','21:00:00'), nota='Pidió que le llamen después de las 3', gest=1, meses=16)
        pr(504, 'Juan Carlos Mendoza Tróchez', 'PREST. QUINCENAL', '2026-04-18', 10000, 10000, 800, 0, 'Día 15', '3356-9014', None, aplica='sin_abono', meses=7)
        pr(505, 'Sonia Marisol Pineda Castro', 'PREST. QUINCENAL', '2025-02-10', 25000, 18400, 1472, 120, 'Día 15', '9925-1170', None, res='lo_pensara', seg=iso('2026-11-28','15:00:00'), nota='Lo va a consultar con el esposo', gest=1, meses=21)
        pr(506, 'Edwin Alexander Lagos Funes', 'PREST. SEMANAL', '2025-06-02', 8000, 7600, 1300, 45, 'Día viernes', '8790-6623', None, meses=17)
        pr(507, 'Ingrid Carolina Bonilla Reyes', 'PREST. QUINCENAL', '2025-09-15', 18000, 15000, 1200, 0, 'Día 15', None, None, res='no_contesta', gest=2, meses=14)
        pr(508, 'Mario Roberto Cálix Sevilla', 'PREST. MENSUAL', '2025-01-20', 30000, 22000, 4400, 0, 'Día 30', '9418-5530', None, res='no_interesa', nota='Prefiere seguir pagando solo intereses', gest=1, meses=22)
        self.niv = P
        self.niv_gest = [
            dict(id=1, p=503, autor_id=GESTOR, autor='Carlos Mejía', r='volver_llamar', nota='Pidió que le llamen después de las 3', seg=iso('2026-11-27','21:00:00'), monto=None, sol=None, en=iso('2026-11-26','17:00:00')),
            dict(id=2, p=505, autor_id=GESTOR, autor='Carlos Mejía', r='lo_pensara', nota='Lo va a consultar con el esposo', seg=iso('2026-11-28','15:00:00'), monto=None, sol=None, en=iso('2026-11-26','17:10:00')),
            dict(id=3, p=507, autor_id=GESTOR, autor='Carlos Mejía', r='no_contesta', nota=None, seg=None, monto=None, sol=None, en=iso('2026-11-25','15:00:00')),
            dict(id=4, p=507, autor_id=GESTOR, autor='Carlos Mejía', r='no_contesta', nota=None, seg=None, monto=None, sol=None, en=iso('2026-11-26','16:00:00')),
            dict(id=5, p=508, autor_id=GESTOR, autor='Carlos Mejía', r='no_interesa', nota='Prefiere seguir pagando solo intereses', seg=None, monto=None, sol=None, en=iso('2026-11-26','16:30:00')),
        ]
        self.calls = []

    # ---------- respuestas ----------
    def session(self):
        jwt = b64({'alg': 'HS256'}) + '.' + b64({'sub': self.me, 'role': 'authenticated', 'exp': 4102444800}) + '.x'
        u = dict(id=self.me, aud='authenticated', role='authenticated', email=PERF[self.me]['email'])
        return dict(access_token=jwt, refresh_token='r', token_type='bearer', expires_in=99999999, expires_at=4102444800, user=u)

    def now(self):
        return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + 'Z'

    def niv_datos(self):
        return dict(todos=False, carga=False, params=dict(antig=12, sin_abono=6, tol=0), carteras=CART, mias=[2],
                    ultima=dict(archivo='Lista_Prestamos.xlsx', en=iso('2026-11-27','14:00:00'), por='Administrador', filas=8, nuevos=8, salieron=0, omitidos=0),
                    rows=copy.deepcopy(self.niv), gestiones=sorted(copy.deepcopy(self.niv_gest), key=lambda g: g['en'], reverse=True))

    def rpc(self, fn, a):
        self.calls.append((fn, a))
        if fn == 'gestor_datos':
            return dict(carteras=CART, mias=[2], sols=copy.deepcopy(self.sols))
        if fn == 'buscar_cliente':
            d = re.sub(r'\D', '', a.get('p_dni') or '')
            c = self.clientes.get(d)
            if not c: return dict(encontrado=False)
            return dict(encontrado=True, nombre=c['nombre'], telefono=c['telefono'], fecha_ingreso=c['fecha_ingreso'], n=2, cartera_sugerida=c['cartera'],
                        tiene_domicilio=True, tiene_trabajo=True,
                        ultima=dict(id=1, codigo=c['codigo'], tipo=c['tipo'], estado=c['estado'], fecha=c['fecha'], desembolsada=c['desembolsada']),
                        abierta=dict(id=4102, codigo=c['codigo'], estado=c['estado']) if c.get('abierta') else None)
        if fn == 'gestor_crear_solicitud':
            d = re.sub(r'\D', '', a.get('p_dni') or '')
            self.next_sol += 1
            s = dict(id=self.next_sol, codigo=f'CR-{self.next_sol}', nombre_cliente=a.get('p_nombre'), tipo=a.get('p_tipo'), estado='borrador', cartera_id=a.get('p_cartera'),
                     dni=f'{d[:4]}-{d[4:8]}-{d[8:]}', telefono=a.get('p_telefono'), creado_en=self.now(), estado_desde=self.now(), desembolsado_en=None, en_espera=False,
                     analisis_tomado=False, es_mia=True, registro='Carlos Mejía', asesor='Daniela Paz')
            self.sols.insert(0, s)
            return dict(id=s['id'], codigo=s['codigo'])
        if fn == 'niv_datos':
            return self.niv_datos()
        if fn == 'niv_gestionar':
            r = next(x for x in self.niv if x['id'] == a['p_id'])
            res = a['p_resultado']
            r.update(resultado=res, resultado_en=self.now(), resultado_por='Carlos Mejía', nota=(a.get('p_nota') or None),
                     seguimiento_en=None if res in ('acepta', 'no_interesa') else a.get('p_seguimiento'), gestiones=r['gestiones'] + 1)
            if a.get('p_telefono'): r['telefono'] = a['p_telefono']
            self.niv_gest.append(dict(id=len(self.niv_gest) + 1, p=r['id'], autor_id=GESTOR, autor='Carlos Mejía', r=res, nota=a.get('p_nota') or None,
                                      seg=a.get('p_seguimiento'), monto=None, sol=None, en=self.now()))
            return dict(ok=True)
        if fn == 'niv_telefono':
            r = next(x for x in self.niv if x['id'] == a['p_id']); r['telefono'] = a.get('p_telefono'); return None
        if fn == 'niv_crear_solicitud':
            r = next(x for x in self.niv if x['id'] == a['p_id'])
            d = re.sub(r'\D', '', a.get('p_dni') or '')
            self.next_sol += 1
            sid = self.next_sol
            r.update(resultado='solicitud', resultado_en=self.now(), resultado_por='Carlos Mejía', seguimiento_en=None, gestiones=r['gestiones'] + 1,
                     dni=f'{d[:4]}-{d[4:8]}-{d[8:]}', sol=dict(id=sid, codigo=f'CR-{sid}', estado='borrador', en_espera=False, analisis_tomado=False,
                                                              desembolsado_en=None, monto=a.get('p_monto'), asesor='Daniela Paz'))
            if a.get('p_telefono'): r['telefono'] = a['p_telefono']
            self.niv_gest.append(dict(id=len(self.niv_gest) + 1, p=r['id'], autor_id=GESTOR, autor='Carlos Mejía', r='solicitud', nota=a.get('p_nota') or None,
                                      seg=None, monto=None, sol=sid, en=self.now()))
            self.sols.insert(0, dict(id=sid, codigo=f'CR-{sid}', nombre_cliente=r['nombre'], tipo='cambio_modalidad', estado='borrador', cartera_id=2,
                                     dni=r['dni'], telefono=r['telefono'], creado_en=self.now(), estado_desde=self.now(), desembolsado_en=None, en_espera=False,
                                     analisis_tomado=False, es_mia=True, registro='Carlos Mejía', asesor='Daniela Paz'))
            return dict(id=sid, codigo=f'CR-{sid}')
        return None

    def handle(self, route):
        req = route.request; u = req.url
        if 'supabase-js' in u: return route.fulfill(path=WWW + '/lib/supabase.js', content_type='application/javascript')
        if 'html2canvas' in u: return route.fulfill(path=WWW + '/lib/html2canvas.min.js', content_type='application/javascript')
        if 'jspdf' in u: return route.fulfill(path=WWW + '/lib/jspdf.umd.min.js', content_type='application/javascript')
        if 'xlsx' in u and u.endswith('.js'): return route.fulfill(path=WWW + '/lib/xlsx.full.min.js', content_type='application/javascript')
        if u.startswith('http://localhost') or u.startswith('http://127.0.0.1'): return route.continue_()
        if 'supabase.co' not in u:
            return route.fulfill(status=200, body='', content_type='text/css')
        path = u.split('supabase.co', 1)[1]
        single = 'vnd.pgrst.object' in (req.headers.get('accept') or '')
        body = None
        if path.startswith('/auth/v1/token'):
            self.logged = True; body = self.session()
        elif path.startswith('/auth/v1/logout'):
            self.logged = False; return route.fulfill(status=204, body='')
        elif path.startswith('/auth/v1/user'):
            body = self.session()['user']
        elif path.startswith('/auth/'):
            body = {}
        elif '/rest/v1/rpc/' in path:
            fn = path.split('/rpc/')[1].split('?')[0]
            try: a = json.loads(req.post_data or '{}')
            except Exception: a = {}
            body = self.rpc(fn, a)
        elif path.startswith('/rest/v1/perfiles'):
            sel = [PERF[self.me]] if 'id=eq.' in path else list(PERF.values())
            body = sel[0] if single else sel
        elif path.startswith('/rest/v1/carteras'):
            body = CART
        elif path.startswith('/rest/v1/parametros'):
            body = [dict(clave=k, valor=v, descripcion=k) for k, v in dict(cartera_nuevas=4, linea_minimo=3000, techo_refi=30000).items()]
        else:
            body = None if single else []
        route.fulfill(status=200, body=json.dumps(body), content_type='application/json')

-- Celebración cuando se alcanza la meta diaria de colocación.
-- Se calcula en la base (con todas las solicitudes, igual que el tablero) al desembolsar; la primera vez que el
-- colocado del día llega a la meta se guarda en "celebraciones": todos los usuarios la ven en la app (tiempo real
-- o al abrirla ese día) y además reciben un aviso push.
create table if not exists public.celebraciones (
  dia date primary key,
  tipo text not null default 'meta',
  monto numeric not null,
  meta numeric not null,
  creado_en timestamptz not null default now()
);
alter table public.celebraciones enable row level security;
create policy celebraciones_sel on public.celebraciones for select using ((select mi_rol()) is not null);
alter publication supabase_realtime add table public.celebraciones;

create or replace function private.meta_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare d date; w int; m numeric; c numeric; sec text;
begin
  if new.estado <> 'desembolsada' or old.estado = 'desembolsada' or coalesce(new.importado, false) then return null; end if;
  d := (coalesce(new.cerrado_en, new.desembolsado_en, now()) at time zone 'America/Tegucigalpa')::date;
  if d <> (now() at time zone 'America/Tegucigalpa')::date or exists (select 1 from celebraciones where dia = d) then return null; end if;
  w := extract(dow from d);
  if w = 0 or exists (select 1 from feriados where fecha = d) then return null; end if;
  m := coalesce((select valor::numeric from parametros where clave = case when w = 6 then 'meta_diaria_sab' else 'meta_diaria_lv' end),
                case when w = 6 then 20000 else 40000 end);
  if m <= 0 then return null; end if;
  -- Capital colocado (igual que capitalColocado() en la app)
  select coalesce(sum(coalesce(capital_colocado_hist,
           case when tipo = 'nuevo' then coalesce(nullif(monto_solicitado, 0), monto_aprobado, 0)
                else greatest(0, coalesce(nullif(monto_solicitado, 0), monto_aprobado, 0) - coalesce(saldo_capital, 0)) end)), 0)
    into c from solicitudes
   where estado = 'desembolsada' and (coalesce(cerrado_en, desembolsado_en) at time zone 'America/Tegucigalpa')::date = d;
  if c < m then return null; end if;
  insert into celebraciones (dia, monto, meta) values (d, c, m) on conflict (dia) do nothing;
  if not found then return null; end if;
  select v into sec from private.push_config where k = 'secreto';
  perform net.http_post(
    url := 'https://edmvfqelxsxevpmxgbav.supabase.co/functions/v1/push',
    body := jsonb_build_object('tabla', 'meta', 'dia', d, 'monto', c, 'meta', m),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-vc-secreto', sec),
    timeout_milliseconds := 10000);
  return null;
exception when others then
  return null;   -- nunca impide guardar el desembolso
end $$;

create trigger meta_dia after update of estado on public.solicitudes
  for each row execute function private.meta_check();

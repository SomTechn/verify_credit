-- Refinanciar: bloqueo de clientes (línea de crédito cerrada). Se guarda por cliente, así que se conserva entre cortes.
alter table public.refi_clientes
  add column if not exists bloqueado boolean not null default false,
  add column if not exists motivo_bloqueo text,
  add column if not exists bloqueado_en timestamptz,
  add column if not exists bloqueado_por uuid;

create or replace function public.refi_clientes_guard() returns trigger
language plpgsql set search_path = public as $$
declare r text := mi_rol();
begin
  if auth.uid() is null then return new; end if;
  if r is null then raise exception 'Sin permiso'; end if;
  if r = 'asesor' then
    if tg_op = 'INSERT' and (new.limite is not null or new.aplica is not null or new.nivel is not null or new.bloqueado) then
      raise exception 'Solo el analista puede asignar el límite, su nivel, decidir si aplica o bloquear al cliente';
    end if;
    if tg_op = 'UPDATE' and (new.limite is distinct from old.limite or new.aplica is distinct from old.aplica or new.nivel is distinct from old.nivel
        or new.bloqueado is distinct from old.bloqueado or new.motivo_bloqueo is distinct from old.motivo_bloqueo) then
      raise exception 'Solo el analista puede asignar el límite, su nivel, decidir si aplica o bloquear al cliente';
    end if;
  end if;
  if new.bloqueado and (tg_op = 'INSERT' or not old.bloqueado) then
    new.bloqueado_en := now(); new.bloqueado_por := auth.uid();
  elsif not new.bloqueado then
    new.bloqueado_en := null; new.bloqueado_por := null;
  else
    new.bloqueado_en := old.bloqueado_en; new.bloqueado_por := old.bloqueado_por;
  end if;
  new.actualizado_por := auth.uid();
  new.actualizado_en := now();
  return new;
end $$;

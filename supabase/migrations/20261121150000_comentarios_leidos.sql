-- Comentarios leídos por usuario (para avisar de comentarios nuevos)
create table if not exists public.comentarios_leidos (
  usuario_id uuid not null references public.perfiles(id) on delete cascade,
  solicitud_id bigint not null references public.solicitudes(id) on delete cascade,
  leido_en timestamptz not null default now(),
  primary key (usuario_id, solicitud_id)
);
alter table public.comentarios_leidos enable row level security;
drop policy if exists com_leidos_sel on public.comentarios_leidos;
create policy com_leidos_sel on public.comentarios_leidos for select using (usuario_id = auth.uid());

create or replace function public.marcar_comentarios_leidos(p_id bigint)
returns timestamptz language sql security definer set search_path = public as $$
  insert into comentarios_leidos (usuario_id, solicitud_id, leido_en)
  select auth.uid(), p_id, now() where auth.uid() is not null and mi_rol() is not null
  on conflict (usuario_id, solicitud_id) do update set leido_en = excluded.leido_en
  returning leido_en;
$$;
revoke all on function public.marcar_comentarios_leidos(bigint) from public, anon;
grant execute on function public.marcar_comentarios_leidos(bigint) to authenticated;

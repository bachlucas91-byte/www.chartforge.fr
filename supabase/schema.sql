-- ChartForge backend foundation for Supabase/Postgres.
-- Run in a new Supabase project. Never expose the service_role key in the browser.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-zA-Z0-9_]{2,30}$'),
  display_name text not null default 'ChartForge creator',
  bio text not null default '',
  avatar_url text,
  role text not null default 'user' check (role in ('user','moderator','admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.datasets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null default 'Untitled dataset',
  time_label text not null default 'Time',
  categories jsonb not null default '[]'::jsonb check (jsonb_typeof(categories) = 'array'),
  rows jsonb not null default '[]'::jsonb check (jsonb_typeof(rows) = 'array'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  dataset_id uuid references public.datasets(id) on delete set null,
  title text not null check (length(trim(title)) between 1 and 160),
  description text not null default '',
  chart_type text not null default 'bar-race' check (chart_type in ('bar-race','line','area','bar','column','pie','donut','scatter','ranking')),
  chart_config jsonb not null default '{}'::jsonb check (jsonb_typeof(chart_config) = 'object'),
  thumbnail_url text,
  visibility text not null default 'private' check (visibility in ('private','public')),
  status text not null default 'draft' check (status in ('draft','pending','published','approved','rejected','hidden')),
  category text not null default 'Data stories',
  views_count bigint not null default 0 check (views_count >= 0),
  likes_count bigint not null default 0 check (likes_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  constraint public_projects_must_be_visible check (
    status not in ('published','approved') or visibility = 'public'
  )
);

create table if not exists public.project_likes (
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (project_id,user_id)
);

create table if not exists public.project_views (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  viewer_id uuid references public.profiles(id) on delete set null,
  viewed_at timestamptz not null default now()
);

create table if not exists public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followed_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id,followed_id),
  check (follower_id <> followed_id)
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  reporter_id uuid references public.profiles(id) on delete set null,
  reason text not null check (length(trim(reason)) between 2 and 120),
  details text not null default '',
  status text not null default 'open' check (status in ('open','dismissed','actioned')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null unique,
  created_at timestamptz not null default now()
);

create index if not exists projects_owner_updated_idx on public.projects(owner_id,updated_at desc);
create index if not exists projects_public_updated_idx on public.projects(updated_at desc) where visibility='public' and status in ('published','approved');
create index if not exists projects_public_popular_idx on public.projects(likes_count desc,views_count desc) where visibility='public' and status in ('published','approved');
create index if not exists reports_open_idx on public.reports(created_at desc) where status='open';
create index if not exists project_views_project_date_idx on public.project_views(project_id,viewed_at desc);

create or replace function public.current_chartforge_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'user');
$$;

create or replace function public.is_chartforge_moderator()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_chartforge_role() in ('moderator','admin');
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.protect_profile_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null
     and public.current_chartforge_role() <> 'admin' then
    raise exception 'Only a trusted administrator can change a profile role';
  end if;
  return new;
end;
$$;

create or replace function public.sync_project_like_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.projects set likes_count = likes_count + 1 where id = new.project_id;
    return new;
  else
    update public.projects set likes_count = greatest(0, likes_count - 1) where id = old.project_id;
    return old;
  end if;
end;
$$;

create or replace function public.sync_project_view_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.projects set views_count = views_count + 1 where id = new.project_id;
  return new;
end;
$$;

drop trigger if exists profiles_protect_role on public.profiles;
create trigger profiles_protect_role before update on public.profiles
for each row execute function public.protect_profile_role();
drop trigger if exists profiles_touch_updated on public.profiles;
create trigger profiles_touch_updated before update on public.profiles
for each row execute function public.touch_updated_at();
drop trigger if exists datasets_touch_updated on public.datasets;
create trigger datasets_touch_updated before update on public.datasets
for each row execute function public.touch_updated_at();
drop trigger if exists projects_touch_updated on public.projects;
create trigger projects_touch_updated before update on public.projects
for each row execute function public.touch_updated_at();
drop trigger if exists likes_update_count on public.project_likes;
create trigger likes_update_count after insert or delete on public.project_likes
for each row execute function public.sync_project_like_count();
drop trigger if exists views_update_count on public.project_views;
create trigger views_update_count after insert on public.project_views
for each row execute function public.sync_project_view_count();

alter table public.profiles enable row level security;
alter table public.datasets enable row level security;
alter table public.projects enable row level security;
alter table public.project_likes enable row level security;
alter table public.project_views enable row level security;
alter table public.follows enable row level security;
alter table public.reports enable row level security;
alter table public.categories enable row level security;

drop policy if exists "Profiles are public to read" on public.profiles;
create policy "Profiles are public to read" on public.profiles for select using (true);
drop policy if exists "Users create their own profile" on public.profiles;
create policy "Users create their own profile" on public.profiles for insert to authenticated with check (id = auth.uid() and role = 'user');
drop policy if exists "Users update their own profile" on public.profiles;
create policy "Users update their own profile" on public.profiles for update to authenticated using (id = auth.uid() or public.current_chartforge_role() = 'admin') with check (id = auth.uid() or public.current_chartforge_role() = 'admin');

drop policy if exists "Owners and moderators read datasets" on public.datasets;
create policy "Owners and moderators read datasets" on public.datasets for select to authenticated using (owner_id = auth.uid() or public.is_chartforge_moderator());
drop policy if exists "Public project datasets are readable" on public.datasets;
create policy "Public project datasets are readable" on public.datasets for select using (exists (select 1 from public.projects p where p.dataset_id = id and p.visibility='public' and p.status in ('published','approved')));
drop policy if exists "Owners create datasets" on public.datasets;
create policy "Owners create datasets" on public.datasets for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists "Owners update datasets" on public.datasets;
create policy "Owners update datasets" on public.datasets for update to authenticated using (owner_id = auth.uid() or public.current_chartforge_role() = 'admin') with check (owner_id = auth.uid() or public.current_chartforge_role() = 'admin');
drop policy if exists "Owners delete datasets" on public.datasets;
create policy "Owners delete datasets" on public.datasets for delete to authenticated using (owner_id = auth.uid() or public.current_chartforge_role() = 'admin');

drop policy if exists "Read public projects or own projects" on public.projects;
create policy "Read public projects or own projects" on public.projects for select using ((visibility='public' and status in ('published','approved')) or owner_id = auth.uid() or public.is_chartforge_moderator());
drop policy if exists "Owners create projects" on public.projects;
create policy "Owners create projects" on public.projects for insert to authenticated with check (owner_id = auth.uid());
drop policy if exists "Owners and moderators update projects" on public.projects;
create policy "Owners and moderators update projects" on public.projects for update to authenticated using (owner_id = auth.uid() or public.is_chartforge_moderator()) with check (owner_id = auth.uid() or public.is_chartforge_moderator());
drop policy if exists "Owners and admins delete projects" on public.projects;
create policy "Owners and admins delete projects" on public.projects for delete to authenticated using (owner_id = auth.uid() or public.current_chartforge_role() = 'admin');

drop policy if exists "Read likes for public charts" on public.project_likes;
create policy "Read likes for public charts" on public.project_likes for select using (exists (select 1 from public.projects p where p.id=project_id and p.visibility='public' and p.status in ('published','approved')) or user_id=auth.uid() or public.is_chartforge_moderator());
drop policy if exists "Authenticated users like public charts" on public.project_likes;
create policy "Authenticated users like public charts" on public.project_likes for insert to authenticated with check (user_id=auth.uid() and exists (select 1 from public.projects p where p.id=project_id and p.visibility='public' and p.status in ('published','approved')));
drop policy if exists "Users remove their likes" on public.project_likes;
create policy "Users remove their likes" on public.project_likes for delete to authenticated using (user_id=auth.uid() or public.current_chartforge_role()='admin');

drop policy if exists "Public chart views can be recorded" on public.project_views;
create policy "Public chart views can be recorded" on public.project_views for insert with check ((viewer_id is null or viewer_id=auth.uid()) and exists (select 1 from public.projects p where p.id=project_id and p.visibility='public' and p.status in ('published','approved')));
drop policy if exists "Moderators read view events" on public.project_views;
create policy "Moderators read view events" on public.project_views for select to authenticated using (public.is_chartforge_moderator());

drop policy if exists "Follow relationships are readable" on public.follows;
create policy "Follow relationships are readable" on public.follows for select using (true);
drop policy if exists "Users follow from their own account" on public.follows;
create policy "Users follow from their own account" on public.follows for insert to authenticated with check (follower_id=auth.uid());
drop policy if exists "Users unfollow from their own account" on public.follows;
create policy "Users unfollow from their own account" on public.follows for delete to authenticated using (follower_id=auth.uid());

drop policy if exists "Users create reports" on public.reports;
create policy "Users create reports" on public.reports for insert with check (reporter_id is null or reporter_id=auth.uid());
drop policy if exists "Reporters and moderators read reports" on public.reports;
create policy "Reporters and moderators read reports" on public.reports for select using (reporter_id=auth.uid() or public.is_chartforge_moderator());
drop policy if exists "Moderators review reports" on public.reports;
create policy "Moderators review reports" on public.reports for update to authenticated using (public.is_chartforge_moderator()) with check (public.is_chartforge_moderator());

drop policy if exists "Categories are public to read" on public.categories;
create policy "Categories are public to read" on public.categories for select using (true);
drop policy if exists "Admins manage categories" on public.categories;
create policy "Admins manage categories" on public.categories for all to authenticated using (public.current_chartforge_role()='admin') with check (public.current_chartforge_role()='admin');

-- Create the profile row after email/OAuth signup; role always begins as 'user'.
create or replace function public.handle_new_chartforge_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  base_name text;
  clean_name text;
begin
  base_name := coalesce(new.raw_user_meta_data->>'username', split_part(coalesce(new.email,'creator'), '@', 1));
  clean_name := regexp_replace(lower(base_name), '[^a-z0-9_]', '_', 'g');
  insert into public.profiles(id,username,display_name)
  values(new.id, left(clean_name,24) || '_' || substr(new.id::text,1,5), coalesce(new.raw_user_meta_data->>'display_name','ChartForge creator'))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_chartforge on auth.users;
create trigger on_auth_user_created_chartforge after insert on auth.users
for each row execute function public.handle_new_chartforge_user();

-- Table privileges are required in addition to row-level policies. RLS still
-- limits each operation to the public rows or the signed-in user's own rows.
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.projects, public.datasets, public.project_likes, public.categories to anon;
grant insert on public.project_views, public.reports to anon;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.projects, public.datasets to authenticated;
grant select, insert, delete on public.project_likes to authenticated;
grant select, insert on public.project_views to authenticated;
grant select, insert, update on public.reports to authenticated;
grant select on public.follows to anon;
grant select, insert, delete on public.follows to authenticated;
grant select, insert, update, delete on public.categories to authenticated;
grant usage, select on sequence public.project_views_id_seq to anon, authenticated;

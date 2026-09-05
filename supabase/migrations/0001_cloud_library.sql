-- Optional cloud library. Local-only mode works without this migration.
create table if not exists public.tracks(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id) on delete cascade,name text not null check(char_length(name) between 1 and 300),storage_path text not null unique,size_bytes bigint not null check(size_bytes>0),mime_type text not null default 'audio/mpeg',created_at timestamptz not null default now());
alter table public.tracks enable row level security;
create policy "Users read their own tracks" on public.tracks for select to authenticated using((select auth.uid())=user_id);
create policy "Users add their own tracks" on public.tracks for insert to authenticated with check((select auth.uid())=user_id);
create policy "Users delete their own tracks" on public.tracks for delete to authenticated using((select auth.uid())=user_id);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('mp3-library','mp3-library',false,104857600,array['audio/mpeg'])on conflict(id)do nothing;
create policy "Users upload their own audio" on storage.objects for insert to authenticated with check(bucket_id='mp3-library' and(storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Users play their own audio" on storage.objects for select to authenticated using(bucket_id='mp3-library' and(storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Users delete their own audio" on storage.objects for delete to authenticated using(bucket_id='mp3-library' and(storage.foldername(name))[1]=(select auth.uid())::text);

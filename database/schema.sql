begin;

create schema if not exists cryptoscreen;

do $$
begin
  create type cryptoscreen.sealed_message_read_policy as enum (
    'app_only',
    'web_allowed'
  );
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  create type cryptoscreen.sealed_message_consume_status as enum (
    'opened',
    'wrong_pin',
    'destroyed',
    'expired',
    'unavailable'
  );
exception
  when duplicate_object then null;
end;
$$;

create table if not exists cryptoscreen.sealed_messages (
  id uuid primary key,
  ciphertext bytea not null,
  nonce bytea not null,
  tag bytea not null,
  salt bytea not null,
  pin_verifier bytea not null,
  revoke_verifier bytea,
  failed_attempts smallint not null default 0,
  max_attempts smallint not null default 3,
  retained boolean not null default false,
  read_policy cryptoscreen.sealed_message_read_policy not null default 'app_only',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint sealed_messages_attempts_check
    check (failed_attempts >= 0 and max_attempts > 0 and failed_attempts <= max_attempts),
  constraint sealed_messages_revoke_verifier_check
    check (revoke_verifier is null or octet_length(revoke_verifier) = 32),
  constraint sealed_messages_expiry_check
    check (expires_at > created_at)
);

create index if not exists sealed_messages_expires_at_idx
  on cryptoscreen.sealed_messages (expires_at);

alter table cryptoscreen.sealed_messages
  add column if not exists retained boolean not null default false;

alter table cryptoscreen.sealed_messages
  add column if not exists revoke_verifier bytea;

alter table cryptoscreen.sealed_messages
  add column if not exists read_policy cryptoscreen.sealed_message_read_policy not null default 'app_only';

do $$
begin
  alter table cryptoscreen.sealed_messages
    add constraint sealed_messages_revoke_verifier_check
    check (revoke_verifier is null or octet_length(revoke_verifier) = 32);
exception
  when duplicate_object then null;
end;
$$;

create table if not exists cryptoscreen.message_stats (
  id boolean primary key default true,
  shared_messages bigint not null default 0,
  image_attachments_shared bigint not null default 0,
  updated_at timestamptz not null default now(),
  constraint message_stats_singleton_check check (id)
);

alter table cryptoscreen.message_stats
  add column if not exists image_attachments_shared bigint not null default 0;

create table if not exists cryptoscreen.sealed_message_attachments (
  id uuid primary key,
  message_id uuid not null references cryptoscreen.sealed_messages (id) on delete cascade,
  object_key text not null unique,
  attachment_type text not null default 'image',
  content_type text not null,
  ciphertext_bytes integer not null,
  encrypted_file_key bytea not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint sealed_message_attachments_one_per_message unique (message_id),
  constraint sealed_message_attachments_type_check
    check (attachment_type = 'image'),
  constraint sealed_message_attachments_content_type_check
    check (content_type in ('image/jpeg', 'image/png', 'image/heic', 'image/heif')),
  constraint sealed_message_attachments_size_check
    check (ciphertext_bytes > 0 and ciphertext_bytes <= 10485760),
  constraint sealed_message_attachments_key_check
    check (octet_length(encrypted_file_key) between 60 and 128),
  constraint sealed_message_attachments_expiry_check
    check (expires_at > created_at)
);

create index if not exists sealed_message_attachments_message_id_idx
  on cryptoscreen.sealed_message_attachments (message_id);

create index if not exists sealed_message_attachments_expires_at_idx
  on cryptoscreen.sealed_message_attachments (expires_at);

create table if not exists cryptoscreen.sealed_message_read_sessions (
  id uuid primary key,
  message_id uuid not null,
  attachment_id uuid not null,
  object_key text not null,
  attachment_type text not null,
  content_type text not null,
  ciphertext_bytes integer not null,
  encrypted_file_key bytea not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint sealed_message_read_sessions_type_check
    check (attachment_type = 'image'),
  constraint sealed_message_read_sessions_content_type_check
    check (content_type in ('image/jpeg', 'image/png', 'image/heic', 'image/heif')),
  constraint sealed_message_read_sessions_size_check
    check (ciphertext_bytes > 0 and ciphertext_bytes <= 10485760),
  constraint sealed_message_read_sessions_key_check
    check (octet_length(encrypted_file_key) between 60 and 128),
  constraint sealed_message_read_sessions_expiry_check
    check (expires_at > created_at)
);

create index if not exists sealed_message_read_sessions_expires_at_idx
  on cryptoscreen.sealed_message_read_sessions (expires_at);

create table if not exists cryptoscreen.sealed_message_read_session_events (
  id bigserial primary key,
  read_session_id uuid not null references cryptoscreen.sealed_message_read_sessions (id) on delete cascade,
  event_type text not null,
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  constraint sealed_message_read_session_events_type_check
    check (event_type in ('screenshot'))
);

create index if not exists sealed_message_read_session_events_session_idx
  on cryptoscreen.sealed_message_read_session_events (read_session_id, received_at);

create table if not exists cryptoscreen.sealed_message_delivery_audit (
  message_id uuid primary key,
  has_image_attachment boolean not null default false,
  text_consumed_at timestamptz,
  interaction_status_opted_in_at timestamptz,
  image_consumed_at timestamptz,
  screenshot_detected_at timestamptz,
  expired_at timestamptz,
  destroyed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table cryptoscreen.sealed_message_delivery_audit
  add column if not exists interaction_status_opted_in_at timestamptz;

create index if not exists sealed_message_delivery_audit_updated_at_idx
  on cryptoscreen.sealed_message_delivery_audit (updated_at);

insert into cryptoscreen.message_stats (id, shared_messages)
values (true, (select count(*) from cryptoscreen.sealed_messages))
on conflict (id) do nothing;

with image_messages as (
  select message_id
  from cryptoscreen.sealed_message_delivery_audit
  where has_image_attachment
  union
  select message_id
  from cryptoscreen.sealed_message_attachments
  where attachment_type = 'image'
)
update cryptoscreen.message_stats
set
  image_attachments_shared = greatest(image_attachments_shared, (select count(*) from image_messages)),
  updated_at = case
    when image_attachments_shared < (select count(*) from image_messages) then now()
    else updated_at
  end
where id = true;

create or replace function cryptoscreen.record_sealed_message_shared()
returns trigger
language plpgsql
security definer
set search_path = cryptoscreen, pg_temp
as $$
begin
  insert into cryptoscreen.message_stats (id, shared_messages, updated_at)
  values (true, 1, now())
  on conflict (id) do update
  set
    shared_messages = cryptoscreen.message_stats.shared_messages + 1,
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists sealed_messages_record_shared on cryptoscreen.sealed_messages;

create trigger sealed_messages_record_shared
after insert on cryptoscreen.sealed_messages
for each row
execute function cryptoscreen.record_sealed_message_shared();

create or replace function cryptoscreen.record_image_attachment_shared()
returns trigger
language plpgsql
security definer
set search_path = cryptoscreen, pg_temp
as $$
begin
  insert into cryptoscreen.message_stats (id, shared_messages, image_attachments_shared, updated_at)
  values (true, 0, 1, now())
  on conflict (id) do update
  set
    image_attachments_shared = cryptoscreen.message_stats.image_attachments_shared + 1,
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists sealed_message_attachments_record_shared on cryptoscreen.sealed_message_attachments;

create trigger sealed_message_attachments_record_shared
after insert on cryptoscreen.sealed_message_attachments
for each row
execute function cryptoscreen.record_image_attachment_shared();

create or replace function cryptoscreen.record_sealed_message_delivery_audit()
returns trigger
language plpgsql
security definer
set search_path = cryptoscreen, pg_temp
as $$
begin
  insert into cryptoscreen.sealed_message_delivery_audit (message_id, created_at, updated_at)
  values (new.id, new.created_at, now())
  on conflict (message_id) do nothing;

  return new;
end;
$$;

drop trigger if exists sealed_messages_record_delivery_audit on cryptoscreen.sealed_messages;

create trigger sealed_messages_record_delivery_audit
after insert on cryptoscreen.sealed_messages
for each row
execute function cryptoscreen.record_sealed_message_delivery_audit();

drop function if exists cryptoscreen.consume_sealed_message(uuid, bytea);

create function cryptoscreen.consume_sealed_message(
  p_id uuid,
  p_pin_verifier bytea
)
returns table (
  status cryptoscreen.sealed_message_consume_status,
  remaining_attempts int,
  retained boolean,
  ciphertext bytea,
  nonce bytea,
  tag bytea,
  salt bytea,
  attachment_id uuid,
  attachment_object_key text,
  attachment_type text,
  attachment_content_type text,
  attachment_ciphertext_bytes int,
  attachment_encrypted_file_key bytea
)
language plpgsql
security definer
set search_path = cryptoscreen, pg_temp
as $$
declare
  sealed cryptoscreen.sealed_messages%rowtype;
  attachment cryptoscreen.sealed_message_attachments%rowtype;
begin
  select *
  into sealed
  from cryptoscreen.sealed_messages
  where id = p_id
  for update;

  if not found then
    status := 'unavailable';
    remaining_attempts := 0;
    retained := false;
    return next;
    return;
  end if;

  if not sealed.retained and sealed.expires_at <= now() then
    update cryptoscreen.sealed_message_delivery_audit
    set
      expired_at = coalesce(expired_at, now()),
      updated_at = now()
    where message_id = p_id;

    delete from cryptoscreen.sealed_messages where id = p_id;
    status := 'expired';
    remaining_attempts := 0;
    retained := false;
    return next;
    return;
  end if;

  if sealed.pin_verifier = p_pin_verifier then
    select *
    into attachment
    from cryptoscreen.sealed_message_attachments
    where message_id = p_id
    limit 1;

    update cryptoscreen.sealed_message_delivery_audit
    set
      text_consumed_at = coalesce(text_consumed_at, now()),
      has_image_attachment = has_image_attachment or attachment.id is not null,
      updated_at = now()
    where message_id = p_id;

    if not sealed.retained then
      delete from cryptoscreen.sealed_messages where id = p_id;
    end if;

    status := 'opened';
    remaining_attempts := sealed.max_attempts - sealed.failed_attempts;
    retained := sealed.retained;
    ciphertext := sealed.ciphertext;
    nonce := sealed.nonce;
    tag := sealed.tag;
    salt := sealed.salt;

    if attachment.id is not null then
      attachment_id := attachment.id;
      attachment_object_key := attachment.object_key;
      attachment_type := attachment.attachment_type;
      attachment_content_type := attachment.content_type;
      attachment_ciphertext_bytes := attachment.ciphertext_bytes;
      attachment_encrypted_file_key := attachment.encrypted_file_key;
    end if;

    return next;
    return;
  end if;

  if sealed.retained then
    status := 'wrong_pin';
    remaining_attempts := sealed.max_attempts;
    retained := true;
    return next;
    return;
  end if;

  if sealed.failed_attempts + 1 >= sealed.max_attempts then
    update cryptoscreen.sealed_message_delivery_audit
    set
      destroyed_at = coalesce(destroyed_at, now()),
      updated_at = now()
    where message_id = p_id;

    delete from cryptoscreen.sealed_messages where id = p_id;
    status := 'destroyed';
    remaining_attempts := 0;
    retained := false;
    return next;
    return;
  end if;

  update cryptoscreen.sealed_messages
  set failed_attempts = failed_attempts + 1
  where id = p_id
  returning failed_attempts, max_attempts
  into sealed.failed_attempts, sealed.max_attempts;

  status := 'wrong_pin';
  remaining_attempts := sealed.max_attempts - sealed.failed_attempts;
  retained := false;
  return next;
end;
$$;

create or replace function cryptoscreen.delete_expired_sealed_messages()
returns bigint
language plpgsql
security definer
set search_path = cryptoscreen, pg_temp
as $$
declare
  deleted_messages bigint;
  deleted_sessions bigint;
  deleted_audits bigint;
begin
  update cryptoscreen.sealed_message_delivery_audit
  set
    expired_at = coalesce(expired_at, now()),
    updated_at = now()
  where message_id in (
    select id
    from cryptoscreen.sealed_messages
    where not retained
      and expires_at <= now()
  );

  delete from cryptoscreen.sealed_messages
  where not retained
    and expires_at <= now();

  get diagnostics deleted_messages = row_count;

  delete from cryptoscreen.sealed_message_read_sessions
  where expires_at <= now();

  get diagnostics deleted_sessions = row_count;

  delete from cryptoscreen.sealed_message_delivery_audit
  where updated_at <= now() - interval '30 days';

  get diagnostics deleted_audits = row_count;
  return deleted_messages + deleted_sessions + deleted_audits;
end;
$$;

comment on schema cryptoscreen is
  'One-time encrypted message storage for cryptoscreen. Plaintext and content keys must never be stored here.';

comment on table cryptoscreen.sealed_messages is
  'Stores ciphertext and online attempt metadata. Normal rows are deleted on correct PIN, third wrong PIN, or expiry. Retained rows are service-owned reusable demo/review rows.';

comment on column cryptoscreen.sealed_messages.pin_verifier is
  'Server-peppered verifier supplied by the API; never store a raw PIN.';

comment on column cryptoscreen.sealed_messages.retained is
  'Service-owned demo/review flag. Retained rows survive correct PIN reads, wrong PIN attempts, and expiry cleanup.';

comment on column cryptoscreen.sealed_messages.read_policy is
  'Controls whether the hosted web reader may consume a message. app_only requires the iOS app or App Clip UI; web_allowed permits browser-side decryption.';

comment on table cryptoscreen.message_stats is
  'Aggregate service counters. shared_messages and image_attachments_shared are cumulative and contain no message content.';

comment on table cryptoscreen.sealed_message_attachments is
  'Stores metadata for one encrypted image attachment per sealed message. R2 stores the ciphertext object; this table stores no plaintext and no raw file key.';

comment on column cryptoscreen.sealed_message_attachments.encrypted_file_key is
  'Combined AES-GCM payload containing the random image key encrypted with the message key.';

comment on table cryptoscreen.sealed_message_read_sessions is
  'Short-lived one-time download sessions for encrypted attachment objects after a successful PIN consume.';

comment on table cryptoscreen.sealed_message_read_session_events is
  'Best-effort reader events such as iOS screenshot detection. Events contain no message plaintext or image plaintext.';

comment on column cryptoscreen.sealed_message_delivery_audit.interaction_status_opted_in_at is
  'Set only when the reader opted into reciprocal interaction status sharing for this read.';

comment on function cryptoscreen.consume_sealed_message(uuid, bytea) is
  'Atomically consumes one PIN attempt. Correct PIN returns ciphertext plus encrypted attachment metadata and deletes normal rows; third wrong PIN deletes normal rows. Retained demo/review rows are reusable.';

commit;

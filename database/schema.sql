begin;

create schema if not exists cryptoscreen;

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
  failed_attempts smallint not null default 0,
  max_attempts smallint not null default 3,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint sealed_messages_attempts_check
    check (failed_attempts >= 0 and max_attempts > 0 and failed_attempts <= max_attempts),
  constraint sealed_messages_expiry_check
    check (expires_at > created_at)
);

create index if not exists sealed_messages_expires_at_idx
  on cryptoscreen.sealed_messages (expires_at);

create or replace function cryptoscreen.consume_sealed_message(
  p_id uuid,
  p_pin_verifier bytea
)
returns table (
  status cryptoscreen.sealed_message_consume_status,
  remaining_attempts int,
  ciphertext bytea,
  nonce bytea,
  tag bytea,
  salt bytea
)
language plpgsql
security definer
set search_path = cryptoscreen, pg_temp
as $$
declare
  sealed cryptoscreen.sealed_messages%rowtype;
begin
  select *
  into sealed
  from cryptoscreen.sealed_messages
  where id = p_id
  for update;

  if not found then
    status := 'unavailable';
    remaining_attempts := 0;
    return next;
    return;
  end if;

  if sealed.expires_at <= now() then
    delete from cryptoscreen.sealed_messages where id = p_id;
    status := 'expired';
    remaining_attempts := 0;
    return next;
    return;
  end if;

  if sealed.pin_verifier = p_pin_verifier then
    delete from cryptoscreen.sealed_messages where id = p_id;
    status := 'opened';
    remaining_attempts := sealed.max_attempts - sealed.failed_attempts;
    ciphertext := sealed.ciphertext;
    nonce := sealed.nonce;
    tag := sealed.tag;
    salt := sealed.salt;
    return next;
    return;
  end if;

  if sealed.failed_attempts + 1 >= sealed.max_attempts then
    delete from cryptoscreen.sealed_messages where id = p_id;
    status := 'destroyed';
    remaining_attempts := 0;
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
  deleted_count bigint;
begin
  delete from cryptoscreen.sealed_messages
  where expires_at <= now();

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

comment on schema cryptoscreen is
  'One-time encrypted message storage for cryptoscreen. Plaintext and content keys must never be stored here.';

comment on table cryptoscreen.sealed_messages is
  'Stores ciphertext and online attempt metadata. Rows are deleted on correct PIN, third wrong PIN, or expiry.';

comment on column cryptoscreen.sealed_messages.pin_verifier is
  'Server-peppered verifier supplied by the API; never store a raw PIN.';

comment on function cryptoscreen.consume_sealed_message(uuid, bytea) is
  'Atomically consumes one PIN attempt. Correct PIN returns ciphertext and deletes the row; third wrong PIN deletes the row.';

commit;

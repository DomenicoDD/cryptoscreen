begin;

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

alter table cryptoscreen.sealed_messages
  add column if not exists read_policy cryptoscreen.sealed_message_read_policy not null default 'app_only';

comment on column cryptoscreen.sealed_messages.read_policy is
  'Controls whether the hosted web reader may consume a message. app_only requires the iOS app or App Clip UI; web_allowed permits browser-side decryption.';

commit;

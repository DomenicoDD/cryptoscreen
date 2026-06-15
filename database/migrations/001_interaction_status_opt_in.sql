begin;

alter table cryptoscreen.sealed_message_delivery_audit
  add column if not exists interaction_status_opted_in_at timestamptz;

comment on column cryptoscreen.sealed_message_delivery_audit.interaction_status_opted_in_at is
  'Set only when the reader opted into reciprocal interaction status sharing for this read.';

commit;

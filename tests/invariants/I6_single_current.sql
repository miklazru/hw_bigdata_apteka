-- I6. Ровно одна текущая версия: два активных (revoked_at IS NULL) согласия
--     одного типа у клиента -> 23505 (partial unique index consent_one_active)
INSERT INTO crm.customer (customer_bk, registered_at)
VALUES ('CUST-9999901', TIMESTAMPTZ '2025-01-01 10:00+00');
INSERT INTO crm.consent (customer_id, consent_type, granted_at)
SELECT customer_id, 'marketing', TIMESTAMPTZ '2025-01-01 10:00+00'
  FROM crm.customer WHERE customer_bk = 'CUST-9999901';
INSERT INTO crm.consent (customer_id, consent_type, granted_at)
SELECT customer_id, 'marketing', TIMESTAMPTZ '2025-06-01 10:00+00'
  FROM crm.customer WHERE customer_bk = 'CUST-9999901';

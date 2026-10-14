-- P2. Soft delete скрывает клиента из контракта:
--   1) клиента нет в contract.v_customer,
--   2) строка физически осталась в crm.customer,
--   3) персональные контакты обнулены (триггер crm.forget_customer).
INSERT INTO crm.customer (customer_bk, birth_date, sex, city, region_code, registered_at)
VALUES ('CUST-9999901', DATE '1990-05-05', 'F', 'Москва', 'RU-MOW', TIMESTAMPTZ '2025-01-01 10:00+00');
INSERT INTO crm.customer_pii (customer_id, full_name, phone, email)
SELECT customer_id, 'Иванова Анна', '+79990000001', 'anna@example.com'
  FROM crm.customer WHERE customer_bk = 'CUST-9999901';

UPDATE crm.customer SET deleted_at = now() WHERE customer_bk = 'CUST-9999901';

SELECT (NOT EXISTS (SELECT 1 FROM contract.v_customer WHERE customer_bk = 'CUST-9999901'))
   AND EXISTS (SELECT 1 FROM crm.customer WHERE customer_bk = 'CUST-9999901')
   AND EXISTS (SELECT 1 FROM crm.customer_pii p JOIN crm.customer c USING (customer_id)
                WHERE c.customer_bk = 'CUST-9999901'
                  AND p.full_name IS NULL AND p.phone IS NULL AND p.email IS NULL
                  AND p.anonymized_at IS NOT NULL) AS ok;

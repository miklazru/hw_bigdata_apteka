-- =============================================================================
-- crm: представления контракта. Забытые клиенты (deleted_at) не попадают.
-- =============================================================================
CREATE VIEW contract.v_customer AS
SELECT c.customer_bk,
       extract(year FROM c.birth_date)::int AS birth_year,
       c.sex::text                          AS sex,
       c.city,
       c.region_code                        AS region,
       c.loyalty_level,
       EXISTS (SELECT 1 FROM crm.consent k
                WHERE k.customer_id = c.customer_id
                  AND k.consent_type = 'marketing'
                  AND k.revoked_at IS NULL) AS marketing_opt_in,
       c.registered_at,
       -- согласие меняет marketing_opt_in, но не строку customer:
       -- берём максимум, иначе инкремент по updated_at пропустит изменение
       GREATEST(c.updated_at,
                coalesce((SELECT max(k.updated_at) FROM crm.consent k
                           WHERE k.customer_id = c.customer_id), c.updated_at)) AS updated_at
  FROM crm.customer c
 WHERE c.deleted_at IS NULL;

-- карты забытых клиентов тоже скрыты (C21: карта ссылается на клиента из v_customer)
CREATE VIEW contract.v_loyalty_card AS
SELECT k.card_bk, c.customer_bk, k.issued_at, k.closed_at, k.status,
       k.bonus_balance, k.updated_at
  FROM crm.loyalty_card k
  JOIN crm.customer c USING (customer_id)
 WHERE c.deleted_at IS NULL;

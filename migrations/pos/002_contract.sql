-- =============================================================================
-- pos: представления контракта
-- =============================================================================
-- все аптеки, включая закрытые: на них ссылаются чеки (C08)
CREATE VIEW contract.v_pharmacy AS
SELECT pharmacy_bk, pharmacy_name,
       region_code AS region,          -- код ISO: X08 сравнивает его со scope_bk цены
       city, address, opened_at, closed_at,
       (closed_at IS NULL AND deleted_at IS NULL) AS is_active,
       updated_at
  FROM pos.pharmacy;

CREATE VIEW contract.v_receipt AS
SELECT r.receipt_bk,
       ph.pharmacy_bk,
       r.customer_bk,
       c.cashier_bk,
       s.shift_bk,
       r.receipt_dt,
       r.doc_type,
       pr.receipt_bk                  AS parent_receipt_bk,
       r.total_amount,
       r.discount_amount,
       r.currency::text               AS currency,
       (SELECT min(p.prescription_bk)
          FROM pos.receipt_line l JOIN pos.prescription p USING (prescription_id)
         WHERE l.receipt_id = r.receipt_id) AS prescription_bk,
       r.updated_at
  FROM pos.receipt r
  JOIN pos.shift s       ON s.shift_id = r.shift_id
  JOIN pos.register g    ON g.register_id = s.register_id
  JOIN pos.pharmacy ph   ON ph.pharmacy_id = g.pharmacy_id
  JOIN pos.cashier c     ON c.cashier_id = s.cashier_id
  LEFT JOIN pos.receipt pr ON pr.receipt_id = r.parent_receipt_id;

CREATE VIEW contract.v_receipt_line AS
SELECT r.receipt_bk, l.line_no, l.sku_bk AS sku, l.batch_bk, l.quantity,
       l.unit_price, l.line_discount, l.line_amount, l.is_rx_snapshot,
       l.sku_name_snapshot, l.updated_at
  FROM pos.receipt_line l
  JOIN pos.receipt r USING (receipt_id);

CREATE VIEW contract.v_payment AS
SELECT r.receipt_bk, p.payment_no, p.payment_method, p.amount,
       p.currency::text AS currency, p.updated_at
  FROM pos.payment p
  JOIN pos.receipt r USING (receipt_id);

-- I11. Возврат больше проданного: продали 2 шт., возвращаем 3
--      -> P0001 (триггер pos.check_receipt_line)
-- тестовая аптека, касса, кассир, смена (BK из диапазона 99xx, зарезервированного под тесты)
INSERT INTO pos.pharmacy (pharmacy_bk, pharmacy_name, region_code, city, address, timezone, opened_at)
VALUES ('PH-9901', 'Тестовая аптека', 'RU-MOW', 'Москва', 'ул. Тестовая, 1', 'Europe/Moscow', DATE '2025-01-01');
INSERT INTO pos.register (register_bk, pharmacy_id)
SELECT 'REG-9901-01', pharmacy_id FROM pos.pharmacy WHERE pharmacy_bk = 'PH-9901';
INSERT INTO pos.cashier (cashier_bk, pharmacy_id)
SELECT 'CSH-99901', pharmacy_id FROM pos.pharmacy WHERE pharmacy_bk = 'PH-9901';
INSERT INTO pos.shift (shift_bk, register_id, cashier_id, opened_at, closed_at)
SELECT 'SHF-9901-01-20260301', g.register_id, c.cashier_id,
       TIMESTAMPTZ '2026-03-01 08:00+03', TIMESTAMPTZ '2026-03-01 22:00+03'
  FROM pos.register g, pos.cashier c
 WHERE g.register_bk = 'REG-9901-01' AND c.cashier_bk = 'CSH-99901';
INSERT INTO pos.receipt (receipt_bk, shift_id, receipt_dt, doc_type, parent_receipt_id, total_amount, discount_amount)
SELECT 'RCPT-29990301-000005', s.shift_id, TIMESTAMPTZ '2026-03-01 12:00+03', 'sale',
       (SELECT receipt_id FROM pos.receipt WHERE receipt_bk = NULL), 100.00, 0
  FROM pos.shift s WHERE s.shift_bk = 'SHF-9901-01-20260301';
INSERT INTO pos.receipt_line (receipt_id, line_no, sku_bk, batch_bk, quantity, unit_price,
                              line_discount, line_amount, sku_name_snapshot, is_rx_snapshot,
                              expiry_date_snapshot)
SELECT receipt_id, 1, 'SKU-999901', 'BATCH-2026-99901', 2, 50.00, 0, 100.00,
       'Тест-препарат', false, DATE '2027-01-01'
  FROM pos.receipt WHERE receipt_bk = 'RCPT-29990301-000005';
INSERT INTO pos.payment (receipt_id, payment_no, payment_method, amount)
SELECT receipt_id, 1, 'card', 100.00 FROM pos.receipt WHERE receipt_bk = 'RCPT-29990301-000005';
INSERT INTO pos.receipt (receipt_bk, shift_id, receipt_dt, doc_type, parent_receipt_id, total_amount, discount_amount)
SELECT 'RCPT-29990301-000006', s.shift_id, TIMESTAMPTZ '2026-03-01 12:00+03', 'refund',
       (SELECT receipt_id FROM pos.receipt WHERE receipt_bk = 'RCPT-29990301-000005'), 150.00, 0
  FROM pos.shift s WHERE s.shift_bk = 'SHF-9901-01-20260301';
INSERT INTO pos.receipt_line (receipt_id, line_no, sku_bk, batch_bk, quantity, unit_price,
                              line_discount, line_amount, sku_name_snapshot, is_rx_snapshot,
                              expiry_date_snapshot)
SELECT receipt_id, 1, 'SKU-999901', 'BATCH-2026-99901', 3, 50.00, 0, 150.00,
       'Тест-препарат', false, DATE '2027-01-01'
  FROM pos.receipt WHERE receipt_bk = 'RCPT-29990301-000006';

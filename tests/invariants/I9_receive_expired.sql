-- I9. Приёмка партии, срок которой истёк на момент приёмки
--     -> P0001 (триггер wms.check_batch_not_expired)
INSERT INTO wms.batch (batch_bk, sku_bk, series_no, manufactured_date, expiry_date, received_at)
VALUES ('BATCH-2026-99902', 'SKU-999901', 'T-0002', DATE '2024-01-01', DATE '2026-01-31',
        TIMESTAMPTZ '2026-03-01 10:00+03');

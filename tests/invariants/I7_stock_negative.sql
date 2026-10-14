-- I7. Остаток не может стать отрицательным: приняли 10, списываем 15
--     -> 23514 (CHECK stock_non_negative, остаток пересчитывает триггер на movement)
INSERT INTO wms.distribution_center (dc_bk, dc_name, region_code, city)
VALUES ('DC-99', 'Тестовый РЦ', 'RU-MOS', 'Раменское');
INSERT INTO wms.location (location_type, location_bk, dc_id)
SELECT 'dc', 'DC-99', dc_id FROM wms.distribution_center WHERE dc_bk = 'DC-99';
INSERT INTO wms.supplier (supplier_bk, supplier_name, country_code)
VALUES ('SUP-9901', 'Тест-Дистрибьютор', 'RU');
INSERT INTO wms.batch (batch_bk, sku_bk, series_no, manufactured_date, expiry_date, received_at)
VALUES ('BATCH-2026-99901', 'SKU-999901', 'T-0001', DATE '2026-01-01', DATE '2028-01-01',
        TIMESTAMPTZ '2026-03-01 10:00+03');
INSERT INTO wms.movement (movement_bk, movement_type, batch_id, src_type, supplier_id,
                          dst_type, dst_location_id, qty, dispatched_at, moved_at)
SELECT 'MOV-29990301-000001', 'receipt', b.batch_id, 'supplier', s.supplier_id,
       'dc', l.location_id, 10, TIMESTAMPTZ '2026-03-01 08:00+03', TIMESTAMPTZ '2026-03-01 10:00+03'
  FROM wms.batch b, wms.supplier s, wms.location l
 WHERE b.batch_bk = 'BATCH-2026-99901' AND s.supplier_bk = 'SUP-9901'
   AND l.location_type = 'dc' AND l.location_bk = 'DC-99';
INSERT INTO wms.movement (movement_bk, movement_type, batch_id, src_type, src_location_id,
                          qty, moved_at, writeoff_reason)
SELECT 'MOV-29990301-000002', 'writeoff', b.batch_id, 'dc', l.location_id,
       15, TIMESTAMPTZ '2026-03-02 10:00+03', 'defect'
  FROM wms.batch b, wms.location l
 WHERE b.batch_bk = 'BATCH-2026-99901' AND l.location_type = 'dc' AND l.location_bk = 'DC-99';

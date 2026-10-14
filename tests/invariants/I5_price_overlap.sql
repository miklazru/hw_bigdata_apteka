-- I5. Пересекающиеся интервалы цены одной (sku, область) -> 23P01 (EXCLUDE price_no_overlap)
INSERT INTO catalog.manufacturer (manufacturer_bk, manufacturer_name, country_code)
VALUES ('MFR-9901', 'Тест-Фарм', 'RU');
INSERT INTO catalog.sku (sku_bk, sku_name, manufacturer_id, category, pack_qty)
SELECT 'SKU-999901', 'Тест-препарат', manufacturer_id, 'otc', 10
  FROM catalog.manufacturer WHERE manufacturer_bk = 'MFR-9901';
INSERT INTO catalog.price (sku_id, price_scope, scope_bk, price, valid_from, valid_to)
SELECT sku_id, 'chain', 'ALL', 100.00, TIMESTAMPTZ '2026-01-01 00:00+00', TIMESTAMPTZ '2026-06-01 00:00+00'
  FROM catalog.sku WHERE sku_bk = 'SKU-999901';
INSERT INTO catalog.price (sku_id, price_scope, scope_bk, price, valid_from, valid_to)
SELECT sku_id, 'chain', 'ALL', 120.00, TIMESTAMPTZ '2026-03-01 00:00+00', NULL
  FROM catalog.sku WHERE sku_bk = 'SKU-999901';

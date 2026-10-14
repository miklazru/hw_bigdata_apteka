-- I1. Business key уникален: два SKU с одним sku_bk -> 23505 (UNIQUE sku_bk)
INSERT INTO catalog.manufacturer (manufacturer_bk, manufacturer_name, country_code)
VALUES ('MFR-9901', 'Тест-Фарм', 'RU');
INSERT INTO catalog.sku (sku_bk, sku_name, manufacturer_id, category, pack_qty)
SELECT 'SKU-999901', 'Тест-препарат', manufacturer_id, 'otc', 10
  FROM catalog.manufacturer WHERE manufacturer_bk = 'MFR-9901';
INSERT INTO catalog.sku (sku_bk, sku_name, manufacturer_id, category, pack_qty)
SELECT 'SKU-999901', 'Другой препарат', manufacturer_id, 'otc', 20
  FROM catalog.manufacturer WHERE manufacturer_bk = 'MFR-9901';

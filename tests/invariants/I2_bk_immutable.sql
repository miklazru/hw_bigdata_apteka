-- I2. Business key неизменяем: UPDATE sku_bk -> P0001 (триггер ref.forbid_bk_change)
INSERT INTO catalog.manufacturer (manufacturer_bk, manufacturer_name, country_code)
VALUES ('MFR-9901', 'Тест-Фарм', 'RU');
INSERT INTO catalog.sku (sku_bk, sku_name, manufacturer_id, category, pack_qty)
SELECT 'SKU-999901', 'Тест-препарат', manufacturer_id, 'otc', 10
  FROM catalog.manufacturer WHERE manufacturer_bk = 'MFR-9901';
UPDATE catalog.sku SET sku_bk = 'SKU-999902' WHERE sku_bk = 'SKU-999901';

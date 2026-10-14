-- P1. updated_at обновляется автоматически.
-- Строка создаётся «вчерашней» (явный updated_at в прошлом): внутри одной
-- транзакции now() постоянен, иначе сравнивать было бы не с чем.
INSERT INTO catalog.manufacturer (manufacturer_bk, manufacturer_name, country_code,
                                  created_at, updated_at)
VALUES ('MFR-9901', 'Тест-Фарм', 'RU', now() - interval '1 day', now() - interval '1 day');
INSERT INTO catalog.sku (sku_bk, sku_name, manufacturer_id, category, pack_qty,
                         created_at, updated_at)
SELECT 'SKU-999901', 'Тест-препарат', manufacturer_id, 'otc', 10,
       now() - interval '1 day', now() - interval '1 day'
  FROM catalog.manufacturer WHERE manufacturer_bk = 'MFR-9901';

UPDATE catalog.sku SET sku_name = sku_name || ' (test)' WHERE sku_bk = 'SKU-999901';

SELECT (updated_at = now() AND updated_at > created_at) AS ok
  FROM catalog.sku WHERE sku_bk = 'SKU-999901';

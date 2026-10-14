-- =============================================================================
-- wms: представления контракта
-- =============================================================================
CREATE VIEW contract.v_supplier AS
SELECT supplier_bk, supplier_name, country_code::text AS country,
       (deleted_at IS NULL) AS is_active, updated_at
  FROM wms.supplier;

CREATE VIEW contract.v_distribution_center AS
SELECT dc_bk, dc_name, region_code AS region, city,
       (deleted_at IS NULL) AS is_active, updated_at
  FROM wms.distribution_center;

CREATE VIEW contract.v_batch AS
SELECT batch_bk, sku_bk AS sku, series_no, manufactured_date, expiry_date,
       received_at, updated_at
  FROM wms.batch;

CREATE VIEW contract.v_purchase_line AS
SELECT p.purchase_bk, l.line_no, s.supplier_bk, d.dc_bk, l.sku_bk AS sku,
       b.batch_bk, p.ordered_at, l.received_at, l.quantity, l.unit_cost,
       l.line_cost, p.currency::text AS currency,
       GREATEST(l.updated_at, p.updated_at) AS updated_at
  FROM wms.purchase_line l
  JOIN wms.purchase p            USING (purchase_id)
  JOIN wms.supplier s            ON s.supplier_id = p.supplier_id
  JOIN wms.distribution_center d ON d.dc_id = p.dc_id
  LEFT JOIN wms.batch b          ON b.batch_id = l.batch_id;

CREATE VIEW contract.v_movement AS
SELECT m.movement_bk, b.batch_bk, b.sku_bk AS sku, m.movement_type,
       m.src_type,
       CASE WHEN m.src_type = 'supplier' THEN sup.supplier_bk ELSE sl.location_bk END AS src_bk,
       m.dst_type,
       dl.location_bk AS dst_bk,
       m.qty, m.dispatched_at, m.moved_at, m.updated_at
  FROM wms.movement m
  JOIN wms.batch b              USING (batch_id)
  LEFT JOIN wms.location sl     ON sl.location_id = m.src_location_id
  LEFT JOIN wms.location dl     ON dl.location_id = m.dst_location_id
  LEFT JOIN wms.supplier sup    ON sup.supplier_id = m.supplier_id;

-- нулевые остатки НЕ скрываем: иначе обнуление партии выглядит для DWH
-- как исчезновение строки, а не как изменение qty_on_hand
CREATE VIEW contract.v_stock AS
SELECT l.location_type, l.location_bk, b.sku_bk AS sku, b.batch_bk,
       s.qty_on_hand, s.updated_at
  FROM wms.stock s
  JOIN wms.location l USING (location_id)
  JOIN wms.batch b    USING (batch_id);

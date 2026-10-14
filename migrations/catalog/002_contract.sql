-- =============================================================================
-- catalog: представления контракта (hw01_contract.yaml)
-- Без now()/random() - детерминированно для сверки мастер/реплика.
-- =============================================================================
CREATE VIEW contract.v_sku AS
SELECT s.sku_bk                                   AS sku,
       s.sku_name,
       (SELECT string_agg(i.inn_name, ' + ' ORDER BY i.inn_name)
          FROM catalog.sku_inn si JOIN catalog.inn i USING (inn_id)
         WHERE si.sku_id = s.sku_id)              AS inn_name,
       m.manufacturer_name,
       f.form_name                                AS drug_form,
       s.category,
       (s.category = 'rx')                        AS is_rx,
       s.is_vital,
       s.pack_qty,
       (s.deleted_at IS NULL)                     AS is_active,
       GREATEST(s.updated_at, m.updated_at,
                coalesce(f.updated_at, s.updated_at)) AS updated_at
  FROM catalog.sku s
  JOIN catalog.manufacturer m USING (manufacturer_id)
  LEFT JOIN catalog.drug_form f USING (drug_form_id);
-- удалённые SKU остаются в контракте с is_active = false:
-- на них ссылаются старые продажи (X01)

CREATE VIEW contract.v_price AS
SELECT s.sku_bk      AS sku,
       p.price_scope,
       p.scope_bk,
       p.price,
       p.currency::text AS currency,
       p.valid_from,
       p.valid_to,
       p.is_current,
       p.updated_at
  FROM catalog.price p
  JOIN catalog.sku s USING (sku_id);

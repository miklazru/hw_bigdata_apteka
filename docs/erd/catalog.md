# catalog_service_db

```mermaid
erDiagram
    region {
        text region_code PK "RU-MOW (ISO 3166-2)"
        text region_name
    }
    manufacturer {
        bigint manufacturer_id PK
        text manufacturer_bk UK "MFR-0001"
        text manufacturer_name
        text country_code "ISO 3166-1 alpha-2"
        timestamptz deleted_at "NULL"
    }
    drug_form {
        bigint drug_form_id PK
        text form_code UK "tablet, solution..."
        text form_name
    }
    inn {
        bigint inn_id PK
        text inn_bk UK "INN-0001"
        text inn_name "МНН"
    }
    sku {
        bigint sku_id PK
        text sku_bk UK "SKU-000148, immutable"
        text sku_name
        bigint manufacturer_id FK
        bigint drug_form_id FK "NULL"
        text category "rx|otc|supplement|device|cosmetics"
        boolean is_vital "ЖНВЛП"
        numeric vital_max_price "NULL; (12,2)"
        numeric pack_qty
        text source_system "CAT"
        timestamptz created_at
        timestamptz updated_at "trigger"
        timestamptz deleted_at "NULL; soft delete"
    }
    sku_inn {
        bigint sku_id PK, FK
        bigint inn_id PK, FK
    }
    sku_history {
        bigint history_id PK
        bigint sku_id FK
        text attr_name "sku_name|category"
        text old_value "NULL"
        text new_value "NULL"
        timestamptz changed_at
    }
    price {
        bigint price_id PK
        bigint sku_id FK
        text price_scope "chain|region|pharmacy"
        text scope_bk "ALL | RU-MOW | PH-0001"
        text region_code FK "NULL; generated from scope_bk"
        numeric price "(12,2) > 0"
        text currency "ISO 4217, RUB"
        timestamptz valid_from
        timestamptz valid_to "NULL = open"
        boolean is_current "generated: valid_to IS NULL"
        timestamptz created_at
        timestamptz updated_at
    }
    EXT_pos_pharmacy {
        text pharmacy_bk "PH-0001"
    }

    manufacturer ||--o{ sku : produces
    drug_form |o--o{ sku : "form of"
    sku ||--o{ sku_inn : contains
    inn ||--o{ sku_inn : "active substance"
    sku ||--o{ sku_history : "change log"
    sku ||--o{ price : "priced by"
    region |o--o{ price : "scope=region"
    EXT_pos_pharmacy |o..o{ price : "scope=pharmacy, BK"
```

Ключевые ограничения:
* `price`: `EXCLUDE USING gist (sku_id WITH =, price_scope WITH =, scope_bk WITH =,
  tstzrange(valid_from, valid_to, '[)') WITH &&)` — I5;
* `price`: `CHECK` на согласованность `price_scope` / `scope_bk`
  (`chain` ⇔ `'ALL'`, `region` ⇔ `^RU-`, `pharmacy` ⇔ `^PH-\d{4}$`);
* `sku.is_rx` не хранится — выводится как `category = 'rx'` ([ADR-0009](../adr/0009-is-rx-derived.md));
* `inn_name` в `v_sku` — `string_agg(inn_name, ' + ' ORDER BY inn_name)`, NULL для нелекарственных.

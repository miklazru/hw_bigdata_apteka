# wms_service_db

```mermaid
erDiagram
    region {
        text region_code PK "RU-MOW"
        text region_name
    }
    supplier {
        bigint supplier_id PK
        text supplier_bk UK "SUP-0001"
        text supplier_name
        text country_code
        timestamptz deleted_at "NULL"
    }
    distribution_center {
        bigint dc_id PK
        text dc_bk UK "DC-01"
        text dc_name
        text region_code FK
        text city
        timestamptz deleted_at "NULL"
    }
    location {
        bigint location_id PK
        text location_type "dc|pharmacy"
        text location_bk "DC-01 | PH-0001; UK with type"
        bigint dc_id FK "NULL; only for dc"
    }
    batch {
        bigint batch_id PK
        text batch_bk UK "BATCH-2026-04417"
        text sku_bk "-> catalog, BK"
        text series_no "UK (sku_bk, series_no)"
        date manufactured_date
        date expiry_date "> manufactured_date"
        timestamptz received_at "I9: not expired"
    }
    purchase {
        bigint purchase_id PK
        text purchase_bk UK "PO-20261014-0042"
        bigint supplier_id FK
        bigint dc_id FK
        timestamptz ordered_at
        text currency
    }
    purchase_line {
        bigint purchase_line_id PK
        bigint purchase_id FK "UK (purchase_id, line_no)"
        int line_no
        text sku_bk "-> catalog, BK"
        numeric quantity "> 0"
        numeric unit_cost ">= 0"
        numeric line_cost "generated: qty * unit_cost"
        bigint batch_id FK "NULL until received"
        timestamptz received_at "NULL; NULL iff batch_id NULL"
    }
    movement {
        bigint movement_id PK
        text movement_bk UK "MOV-20261014-000123"
        text movement_type "receipt|transfer|sale_writeoff|return|writeoff"
        bigint batch_id FK
        text src_type "NULL; dc|pharmacy|supplier"
        bigint src_location_id FK "NULL"
        bigint supplier_id FK "NULL; src for receipt"
        text dst_type "NULL; dc|pharmacy|customer"
        bigint dst_location_id FK "NULL"
        numeric qty "> 0"
        timestamptz dispatched_at "NULL; <= moved_at"
        timestamptz moved_at
        text writeoff_reason "NULL; defect|expired"
    }
    stock {
        bigint location_id PK, FK
        bigint batch_id PK, FK
        numeric qty_on_hand ">= 0 (I7)"
        timestamptz updated_at
    }
    EXT_catalog_sku {
        text sku_bk "SKU-000148"
    }
    EXT_pos_pharmacy {
        text pharmacy_bk "PH-0001"
    }

    region ||--o{ distribution_center : in
    distribution_center |o--o| location : "is"
    EXT_pos_pharmacy |o..o| location : "type=pharmacy, BK"
    EXT_catalog_sku ||..o{ batch : "BK"
    EXT_catalog_sku ||..o{ purchase_line : "BK"
    supplier ||--o{ purchase : "supplies"
    distribution_center ||--o{ purchase : "receives"
    purchase ||--|{ purchase_line : has
    batch |o--o{ purchase_line : "created on receipt"
    batch ||--o{ movement : moves
    location |o--o{ movement : "src / dst"
    supplier |o--o{ movement : "src of receipt"
    location ||--o{ stock : holds
    batch ||--o{ stock : "on hand"
```

Ключевые решения:
* `location` — единая таблица локаций; аптеки в ней — справочная копия из POS по BK;
* `stock` материализован, обновляется триггером на `INSERT` в `movement`
  ([ADR-0004](../adr/0004-stock-materialized.md));
* продажи списываются дневным агрегатом `sale_writeoff` на (аптека, партия, день)
  ([ADR-0007](../adr/0007-sale-writeoff-daily.md));
* `return` = возврат поставщику (`src` = РЦ, `dst` = NULL); товар от покупателя
  в остаток не возвращается.

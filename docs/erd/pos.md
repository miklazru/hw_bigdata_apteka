# pos_service_db

```mermaid
erDiagram
    region {
        text region_code PK "RU-MOW"
        text region_name
    }
    pharmacy {
        bigint pharmacy_id PK
        text pharmacy_bk UK "PH-0001"
        text pharmacy_name
        text region_code FK
        text city
        text address
        text timezone "Europe/Moscow ... Asia/Vladivostok"
        date opened_at
        date closed_at "NULL"
        timestamptz deleted_at "NULL"
    }
    cashier {
        bigint cashier_id PK
        text cashier_bk UK "CSH-00001"
        bigint pharmacy_id FK
        timestamptz deleted_at "NULL"
    }
    register {
        bigint register_id PK
        text register_bk UK "REG-0001-01"
        bigint pharmacy_id FK
    }
    shift {
        bigint shift_id PK
        text shift_bk UK "SHF-0001-01-20261014"
        bigint register_id FK
        bigint cashier_id FK
        timestamptz opened_at
        timestamptz closed_at "NULL = open"
    }
    prescription {
        bigint prescription_id PK
        text prescription_bk UK "RX-20261014-000001"
        date issued_at
        date valid_until
    }
    receipt {
        bigint receipt_id PK
        text receipt_bk UK "RCPT-20261014-000731"
        bigint shift_id FK
        text customer_bk "NULL; -> crm, BK"
        timestamptz receipt_dt
        text doc_type "sale|refund"
        bigint parent_receipt_id FK "NULL; required for refund"
        numeric total_amount "(14,2); I3, I12"
        numeric discount_amount
        text currency "RUB"
        timestamptz created_at
        timestamptz updated_at
    }
    receipt_line {
        bigint receipt_id PK, FK
        int line_no PK
        text sku_bk "-> catalog, BK"
        text batch_bk "-> wms, BK"
        numeric quantity "> 0"
        numeric unit_price "snapshot, >= 0"
        numeric line_discount ">= 0"
        numeric line_amount "CHECK = qty*price - discount (I4)"
        text sku_name_snapshot
        boolean is_rx_snapshot
        date expiry_date_snapshot "I8"
        bigint prescription_id FK "NULL; required if rx (I10)"
    }
    payment {
        bigint receipt_id PK, FK
        int payment_no PK
        text payment_method "cash|card|bonus|certificate"
        numeric amount "> 0"
        text currency
    }
    EXT_crm_customer {
        text customer_bk "CUST-0000001"
    }
    EXT_catalog_sku {
        text sku_bk "SKU-000148"
    }
    EXT_wms_batch {
        text batch_bk "BATCH-2026-04417"
    }

    region ||--o{ pharmacy : in
    pharmacy ||--o{ cashier : employs
    pharmacy ||--o{ register : has
    register ||--o{ shift : "opened on"
    cashier ||--o{ shift : works
    shift ||--o{ receipt : "issued in"
    receipt |o--o{ receipt : "refund of"
    receipt ||--|{ receipt_line : has
    receipt ||--|{ payment : "paid by"
    prescription |o--o{ receipt_line : authorizes
    EXT_crm_customer |o..o{ receipt : "BK, optional"
    EXT_catalog_sku ||..o{ receipt_line : "BK"
    EXT_wms_batch ||..o{ receipt_line : "BK"
```

Ключевые ограничения:
* I3, I12 — `CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED`;
* I4 — `CHECK` на `receipt_line` (`line_amount` — обычная колонка, не generated,
  иначе тест упадёт с `428C9`, а не `23514`);
* I8 — триггер: дата чека (по `timezone` аптеки) ≤ `expiry_date_snapshot`;
* I10 — `CHECK (NOT is_rx_snapshot OR prescription_id IS NOT NULL)`
  ([ADR-0005](../adr/0005-rx-prescription.md));
* I11 — триггер на строки возврата;
* `CHECK ((doc_type = 'refund') = (parent_receipt_id IS NOT NULL))` — C05;
* `v_receipt.prescription_bk` = `min(prescription_bk)` по строкам,
  `v_receipt.pharmacy_bk` / `cashier_bk` — через `shift → register / cashier`;
* `v_pharmacy` отдаёт **все** аптеки, включая закрытые (иначе C08).

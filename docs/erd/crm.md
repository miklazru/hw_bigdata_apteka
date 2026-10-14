# crm_service_db

```mermaid
erDiagram
    region {
        text region_code PK "RU-MOW"
        text region_name
    }
    loyalty_level {
        text level_code PK "basic|silver|gold|platinum"
        text level_name
        int sort_order
    }
    customer {
        bigint customer_id PK
        text customer_bk UK "CUST-0000001"
        date birth_date "NULL"
        text sex "NULL; M|F"
        text city "NULL"
        text region_code FK "NULL"
        text loyalty_level FK "NULL"
        timestamptz registered_at
        text source_system "CRM"
        timestamptz created_at
        timestamptz updated_at
        timestamptz deleted_at "NULL; forget request"
    }
    customer_pii {
        bigint customer_id PK, FK
        text full_name "NULL after anonymization"
        text phone "NULL after anonymization"
        text email "NULL after anonymization"
        timestamptz anonymized_at "NULL"
    }
    customer_history {
        bigint history_id PK
        bigint customer_id FK
        text attr_name "loyalty_level|city|region_code"
        text old_value "NULL"
        text new_value "NULL"
        timestamptz changed_at
    }
    loyalty_card {
        bigint card_id PK
        text card_bk UK "CARD-0000001"
        bigint customer_id FK "one active per customer"
        timestamptz issued_at
        timestamptz closed_at "NULL"
        text status "active|blocked|closed"
        numeric bonus_balance "(12,2) >= 0"
    }
    consent {
        bigint consent_id PK
        bigint customer_id FK
        text consent_type "pd_processing|marketing|sms"
        timestamptz granted_at
        timestamptz revoked_at "NULL = active (I6)"
    }

    region |o--o{ customer : lives
    loyalty_level |o--o{ customer : "current level"
    customer ||--|| customer_pii : "personal data"
    customer ||--o{ customer_history : "change log"
    customer ||--o{ loyalty_card : holds
    customer ||--o{ consent : gives
```

Ключевые ограничения:
* `loyalty_card`: partial unique `(customer_id) WHERE status = 'active'` — C22;
  `CHECK (closed_at IS NULL OR status <> 'active')` — C23;
* `consent`: partial unique `(customer_id, consent_type) WHERE revoked_at IS NULL` — I6;
* триггер: установка `customer.deleted_at` автоматически обезличивает `customer_pii`
  ([ADR-0008](../adr/0008-customer-forget.md));
* `v_customer.marketing_opt_in` = `EXISTS` активного согласия `marketing`, без `now()`;
* пользователь `checker` не имеет доступа к `customer_pii`.

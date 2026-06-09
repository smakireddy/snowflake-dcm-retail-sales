# Building a Retail Sales Analytics Pipeline with Snowflake DCM

## Introduction

Database Change Management (DCM) is Snowflake's native infrastructure-as-code solution. It lets you define your entire data platform — databases, tables, dynamic tables, views, warehouses, and more — as declarative SQL files, then deploy them consistently across environments.

This article walks through building a complete retail sales analytics pipeline using DCM, covering project setup, multi-environment configuration, and production best practices.

## What is DCM?

DCM brings the Terraform/dbt model to Snowflake infrastructure management:

- **Declarative**: You define the desired state, DCM figures out what to create, alter, or drop
- **Idempotent**: Running deploy multiple times is safe — only changes are applied
- **Multi-environment**: One codebase deploys to DEV, STG, and PROD with different configurations
- **Native**: Built into the Snowflake CLI (`snow`), no third-party tools needed

### DCM vs Traditional DDL

```sql
-- Traditional: imperative, order-dependent, not idempotent
CREATE TABLE IF NOT EXISTS my_db.raw.customers (...);
ALTER TABLE my_db.raw.customers ADD COLUMN phone VARCHAR(20);

-- DCM: declarative, dependency-resolved, always idempotent
DEFINE TABLE my_db.raw.customers (
    customer_id NUMBER NOT NULL,
    phone VARCHAR(20)    -- just add it to the definition
);
```

## The Scenario

We're building a retail sales analytics platform with three layers:

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────────┐
│   RAW (Source)  │────▶│  ANALYTICS (Dynamic  │────▶│   SERVE (Views)     │
│                 │     │      Tables)          │     │                     │
│  CUSTOMERS      │     │  DT_CUSTOMER_ORDERS   │     │  VW_CUSTOMER_360    │
│  PRODUCTS       │     │  DT_PRODUCT_SALES     │     │  VW_PRODUCT_PERF    │
│  SALES_ORDERS   │     │  DT_DAILY_SALES_AGG   │     │                     │
│  ORDER_LINE_ITEMS│    │                       │     │                     │
└─────────────────┘     └──────────────────────┘     └─────────────────────┘
```

**Key design choices:**
- Source tables use `CHANGE_TRACKING = TRUE` to enable incremental CDC
- Dynamic tables auto-refresh when source data changes (no scheduling needed)
- Views add business logic (segmentation, performance tiers) without materializing data

## Project Structure

```
retail-sales-project/
├── manifest.yml.example        # Template with placeholders (tracked in git)
├── manifest.yml                # Local config with real values (gitignored)
├── .gitignore
└── sources/
    └── definitions/
        ├── infrastructure.sql  # Database, schemas, warehouse
        ├── tables.sql          # Source tables
        ├── analytics.sql       # Dynamic tables
        ├── serve.sql           # Consumption views
        └── procedures.sql      # Stored procedures
```

### Why This Layout?

- **One file per layer** — easy to find and review changes
- **Flat structure** — no unnecessary nesting for a project with 15 objects
- **Manifest separate from definitions** — config vs logic separation
- **Gitignored manifest** — account-specific values never leak to the repo

## Step 1: The Manifest (Multi-Environment Config)

The manifest is the heart of a DCM project. It defines deployment targets and Jinja templating variables:

```yaml
manifest_version: 2
type: DCM_PROJECT
default_target: 'DEV'

targets:
  DEV:
    account_identifier: <YOUR_ACCOUNT>
    project_name: 'RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV'
    project_owner: ENGINEERING_DEV
    templating_config: 'DEV'
  STG:
    account_identifier: <YOUR_ACCOUNT>
    project_name: 'RETAIL_DB_STG.DCM_PROJECTS.RETAIL_SALES_STG'
    project_owner: ENGINEERING_STG
    templating_config: 'STG'
  PROD:
    account_identifier: <YOUR_ACCOUNT>
    project_name: 'RETAIL_DB_PROD.DCM_PROJECTS.RETAIL_SALES_PROD'
    project_owner: ENGINEERING_PROD
    templating_config: 'PROD'

templating:
  defaults:
    env_suffix: '_DEV'
    wh_size: 'XSMALL'
    dt_lag: '1 hour'
    retention_days: 1
  configurations:
    DEV:
      env_suffix: '_DEV'
      wh_size: 'XSMALL'
      dt_lag: '2 minutes'
    STG:
      env_suffix: '_STG'
      wh_size: 'SMALL'
      dt_lag: '2 minutes'
    PROD:
      env_suffix: '_PROD'
      wh_size: 'MEDIUM'
      dt_lag: '2 minutes'
```

### Key Concepts

- **Each target = one DCM project in Snowflake** — DEV, STG, PROD are separate registrations
- **`templating_config`** links a target to its variable set
- **Variable resolution**: `defaults` → `configurations.<name>` → `--variable` CLI flag (highest priority)
- **Same codebase, different behavior** — warehouse size, refresh lag, and naming all vary by environment

## Step 2: Infrastructure Layer

```sql
-- infrastructure.sql
DEFINE DATABASE RETAIL_DATA{{env_suffix}}
    COMMENT = 'Retail sales data - {{env_suffix}} environment';

DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.RAW
    COMMENT = 'Raw source tables from transactional systems'
    DATA_RETENTION_TIME_IN_DAYS = {{retention_days}};

DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.ANALYTICS
    WITH MANAGED ACCESS
    COMMENT = 'Aggregated analytics via dynamic tables'
    DATA_RETENTION_TIME_IN_DAYS = {{retention_days}};

DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.SERVE
    WITH MANAGED ACCESS
    COMMENT = 'Consumption views for dashboards and reporting';

DEFINE WAREHOUSE RETAIL_WH{{env_suffix}}
WITH
    WAREHOUSE_SIZE = '{{wh_size}}'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    COMMENT = 'Compute for retail analytics pipeline';
```

**Why `WITH MANAGED ACCESS`?** It centralizes grant management on the ANALYTICS and SERVE schemas — only the schema owner can grant privileges, preventing ad-hoc access sprawl.

## Step 3: Source Tables

```sql
-- tables.sql
DEFINE TABLE RETAIL_DATA{{env_suffix}}.RAW.CUSTOMERS (
    CUSTOMER_ID NUMBER NOT NULL,
    FIRST_NAME VARCHAR(100),
    LAST_NAME VARCHAR(100),
    EMAIL VARCHAR(255),
    PHONE VARCHAR(20),
    CITY VARCHAR(100),
    STATE VARCHAR(50),
    SIGNUP_DATE DATE,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CHANGE_TRACKING = TRUE
COMMENT = 'Customer master data from CRM system';

DEFINE TABLE RETAIL_DATA{{env_suffix}}.RAW.SALES_ORDERS (
    ORDER_ID NUMBER NOT NULL,
    CUSTOMER_ID NUMBER NOT NULL,
    ORDER_DATE DATE,
    STATUS VARCHAR(20) DEFAULT 'PENDING',
    TOTAL_AMOUNT NUMBER(12,2),
    PAYMENT_METHOD VARCHAR(50),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CHANGE_TRACKING = TRUE
COMMENT = 'Sales order headers from POS system';
```

**`CHANGE_TRACKING = TRUE`** is critical — without it, dynamic tables cannot detect incremental changes and must do full refreshes every time.

## Step 4: Dynamic Tables (Auto-Refreshing Transformations)

```sql
-- analytics.sql
DEFINE DYNAMIC TABLE RETAIL_DATA{{env_suffix}}.ANALYTICS.DT_CUSTOMER_ORDERS_SUMMARY
WAREHOUSE = 'RETAIL_WH{{env_suffix}}'
TARGET_LAG = '{{dt_lag}}'
INITIALIZE = 'ON_CREATE'
AS
SELECT
    c.CUSTOMER_ID,
    c.FIRST_NAME,
    c.LAST_NAME,
    c.EMAIL,
    c.CITY,
    c.STATE,
    COUNT(DISTINCT o.ORDER_ID) AS TOTAL_ORDERS,
    SUM(o.TOTAL_AMOUNT) AS TOTAL_SPEND,
    AVG(o.TOTAL_AMOUNT) AS AVG_ORDER_VALUE,
    MIN(o.ORDER_DATE) AS FIRST_ORDER_DATE,
    MAX(o.ORDER_DATE) AS LAST_ORDER_DATE
FROM RETAIL_DATA{{env_suffix}}.RAW.CUSTOMERS c
LEFT JOIN RETAIL_DATA{{env_suffix}}.RAW.SALES_ORDERS o
    ON c.CUSTOMER_ID = o.CUSTOMER_ID
GROUP BY
    c.CUSTOMER_ID, c.FIRST_NAME, c.LAST_NAME,
    c.EMAIL, c.CITY, c.STATE;
```

### Why Dynamic Tables?

- **No scheduler needed** — Snowflake handles refresh automatically based on `TARGET_LAG`
- **Incremental** — only processes changed rows (thanks to `CHANGE_TRACKING`)
- **Declarative** — you write a SELECT, Snowflake handles the materialization
- **DAG-aware** — downstream dynamic tables refresh only when upstream data changes

### TARGET_LAG Strategy

| Environment | Lag | Rationale |
|-------------|-----|-----------|
| DEV | 2 minutes | Fast feedback during development |
| STG | 2 minutes | Mirrors production behavior |
| PROD | 2 minutes | Near real-time for dashboards |

Use `'DOWNSTREAM'` instead of a time interval if a dynamic table only needs to refresh when queried by a downstream consumer.

## Step 5: Serving Layer (Views)

```sql
-- serve.sql
DEFINE VIEW RETAIL_DATA{{env_suffix}}.SERVE.VW_CUSTOMER_360
AS
SELECT
    cs.CUSTOMER_ID,
    cs.FIRST_NAME,
    cs.LAST_NAME,
    cs.TOTAL_ORDERS,
    cs.TOTAL_SPEND,
    cs.LAST_ORDER_DATE,
    DATEDIFF('day', cs.LAST_ORDER_DATE, CURRENT_DATE()) AS DAYS_SINCE_LAST_ORDER,
    CASE
        WHEN cs.TOTAL_ORDERS = 0 THEN 'PROSPECT'
        WHEN cs.TOTAL_ORDERS = 1 THEN 'NEW'
        WHEN cs.TOTAL_SPEND >= 1000 THEN 'VIP'
        WHEN DATEDIFF('day', cs.LAST_ORDER_DATE, CURRENT_DATE()) > 90 THEN 'AT_RISK'
        ELSE 'ACTIVE'
    END AS CUSTOMER_SEGMENT
FROM RETAIL_DATA{{env_suffix}}.ANALYTICS.DT_CUSTOMER_ORDERS_SUMMARY cs;
```

Views add **business logic without materialization cost** — segmentation rules, calculated fields, and formatted outputs that change frequently without triggering full rebuilds.

## Step 6: Stored Procedures

```sql
-- procedures.sql
DEFINE PROCEDURE RETAIL_DATA{{env_suffix}}.RAW.CANCEL_CUSTOMER_ORDERS(P_CUSTOMER_ID NUMBER)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE RETAIL_DATA{{env_suffix}}.RAW.SALES_ORDERS
    SET STATUS = 'CANCELLED'
    WHERE CUSTOMER_ID = :P_CUSTOMER_ID
      AND STATUS != 'CANCELLED';

    RETURN 'Cancelled ' || SQLROWCOUNT || ' orders for customer ' || :P_CUSTOMER_ID;
END;
$$;
```

**Note the `:P_CUSTOMER_ID` colon prefix** — this is required for referencing parameters inside SQL statements within Snowflake SQL procedures.

## Deployment Workflow

### Prerequisites (One-Time)

```sql
-- Create the project container (DCM can't define its own parent)
CREATE DATABASE IF NOT EXISTS RETAIL_DB_DEV;
CREATE SCHEMA IF NOT EXISTS RETAIL_DB_DEV.DCM_PROJECTS;

-- Create deployment role
CREATE ROLE IF NOT EXISTS ENGINEERING_DEV;
GRANT CREATE DCM PROJECT ON SCHEMA RETAIL_DB_DEV.DCM_PROJECTS TO ROLE ENGINEERING_DEV;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE ENGINEERING_DEV;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE ENGINEERING_DEV;
```

### Day-to-Day Commands

```bash
# 1. Register project (one-time)
snow dcm create RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV -c <connection>

# 2. Validate definitions (syntax + dependency check)
snow dcm raw-analyze RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV \
  -c <connection> --target DEV

# 3. Preview changes (Terraform plan equivalent)
snow dcm plan RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV \
  -c <connection> --target DEV

# 4. Apply changes
snow dcm deploy RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV \
  -c <connection> --target DEV --alias "describe_your_change"
```

### What Plan Output Looks Like

```
CREATE   DATABASE        RETAIL_DATA_DEV
CREATE   SCHEMA          RETAIL_DATA_DEV.RAW
ALTER    DYNAMIC_TABLE   RETAIL_DATA_DEV.ANALYTICS.DT_DAILY_SALES_AGG

Planned 15 entities (2 to create, 1 to alter, 0 to drop)
```

Only changed objects appear — unchanged objects are silently skipped.

## The Parent Database Constraint

The most common DCM gotcha: **a project cannot DEFINE its own parent database**.

```
Project registered at: RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV
                       ^^^^^^^^^^^^^^
                       Cannot DEFINE this database!

Solution: Define a DIFFERENT database for your data objects
          DEFINE DATABASE RETAIL_DATA_DEV;  ← This is fine
```

This is why we separate the project container (`RETAIL_DB_DEV`) from the data database (`RETAIL_DATA_DEV`).

## Multi-Environment Promotion

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│     DEV      │────▶│     STG      │────▶│     PROD     │
│              │     │              │     │              │
│ RETAIL_DATA  │     │ RETAIL_DATA  │     │ RETAIL_DATA  │
│ _DEV         │     │ _STG         │     │ _PROD        │
│              │     │              │     │              │
│ WH: XSMALL   │     │ WH: SMALL    │     │ WH: MEDIUM   │
│ Lag: 2 min   │     │ Lag: 2 min   │     │ Lag: 2 min   │
└──────────────┘     └──────────────┘     └──────────────┘
```

Same code, different `--target`:

```bash
snow dcm deploy ... --target DEV   # Developer deploys
snow dcm deploy ... --target STG   # CI/CD promotes to staging
snow dcm deploy ... --target PROD  # Release pipeline deploys to production
```

## Developer Sandboxes

Multiple developers can work in parallel without conflicts using `--variable`:

```bash
# Developer A
snow dcm deploy ... --target DEV --variable "env_suffix='_DEV_ALICE'"

# Developer B
snow dcm deploy ... --target DEV --variable "env_suffix='_DEV_BOB'"
```

This creates completely isolated databases (`RETAIL_DATA_DEV_ALICE`, `RETAIL_DATA_DEV_BOB`) from the same definition files.

## Best Practices

### 1. Project Organization

- **Separate project container from data** — avoid the parent database constraint entirely
- **One project per domain** — sales, marketing, finance each get their own project
- **Flat file structure** — nest only when you exceed 50+ objects

### 2. Safety

- **Always `plan` before `deploy`** — review CREATE/ALTER/DROP before applying
- **Use `--alias` on every deploy** — creates an audit trail (`snow dcm list-deployments`)
- **Never deploy with ACCOUNTADMIN** — use least-privilege roles per environment
- **Watch for DROPs** — removing a DEFINE statement causes the object to be dropped on next deploy

### 3. Templating

- **Template everything that varies by environment** — names, sizes, lags, retention
- **Use `defaults` for common values** — override only what differs in each config
- **Keep it simple** — don't over-abstract with complex Jinja when a few variables suffice

### 4. Source Control

- **Gitignore `manifest.yml`** — it contains account identifiers
- **Track `manifest.yml.example`** — with `<PLACEHOLDER>` values for onboarding
- **One commit per logical change** — makes `plan` diffs reviewable in PRs

### 5. Dynamic Tables

- **Always enable `CHANGE_TRACKING`** on source tables — required for incremental refresh
- **Use `INITIALIZE = 'ON_CREATE'`** — verifies data immediately after deploy
- **Choose `TARGET_LAG` based on business need** — shorter lag = more compute cost

## Command Reference

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `snow dcm create` | Register project | Once per environment |
| `snow dcm raw-analyze` | Validate syntax | During development |
| `snow dcm plan` | Preview changes | Before every deploy |
| `snow dcm deploy` | Apply changes | When ready to release |
| `snow dcm refresh` | Trigger DT refresh | Testing after data load |
| `snow dcm preview` | Query managed objects | Quick data checks |
| `snow dcm test` | Run expectations | Data quality validation |
| `snow dcm list-deployments` | Audit trail | Troubleshooting |
| `snow dcm purge` | Drop all objects | Full teardown (dangerous) |

## Conclusion

DCM brings infrastructure-as-code discipline to Snowflake without external tools. The key principles:

1. **DEFINE, don't CREATE** — declarative over imperative
2. **One codebase, many environments** — Jinja templating handles the differences
3. **Plan before deploy** — always review the diff
4. **Let Snowflake do the work** — dynamic tables replace scheduled ETL

The complete source code for this project is available at: [github.com/smakireddy/snowflake-dcm-retail-sales](https://github.com/smakireddy/snowflake-dcm-retail-sales)

# Retail Sales Analytics — DCM Project

## Overview

This project uses **Snowflake Database Change Management (DCM)** to declaratively manage a retail sales analytics pipeline. All infrastructure — databases, schemas, warehouses, tables, dynamic tables, and views — is defined as code and deployed via the Snowflake CLI.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         DCM Project                                  │
│  Registry: RETAIL_DB_<ENV>.DCM_PROJECTS.RETAIL_SALES_<ENV>          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌───────────────┐    ┌──────────────────┐    ┌──────────────────┐ │
│  │  RAW (Source)  │───▶│ ANALYTICS (DTs)  │───▶│  SERVE (Views)   │ │
│  └───────────────┘    └──────────────────┘    └──────────────────┘ │
│                                                                     │
│  CUSTOMERS             DT_CUSTOMER_ORDERS     VW_CUSTOMER_360      │
│  PRODUCTS              DT_PRODUCT_SALES       VW_PRODUCT_PERFORMANCE│
│  SALES_ORDERS          DT_DAILY_SALES_AGG                          │
│  ORDER_LINE_ITEMS                                                   │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  RETAIL_WH_<ENV> (Compute for DT refreshes & queries)        │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Source Systems ──▶ RAW Tables (CHANGE_TRACKING=TRUE)
                        │
                        ▼ (auto-refresh via TARGET_LAG)
                   Dynamic Tables (ANALYTICS schema)
                        │
                        ▼ (real-time)
                   Views (SERVE schema) ──▶ Dashboards / BI Tools
```

## Objects Created

| Layer | Object | Type | Description |
|-------|--------|------|-------------|
| Infrastructure | `RETAIL_DATA_<ENV>` | Database | Core data database |
| Infrastructure | `RAW` | Schema | Landing zone for source data |
| Infrastructure | `ANALYTICS` | Schema (Managed Access) | Transformation layer |
| Infrastructure | `SERVE` | Schema (Managed Access) | Consumption layer |
| Infrastructure | `RETAIL_WH_<ENV>` | Warehouse | Compute for DT refreshes |
| Source | `CUSTOMERS` | Table | Customer master data |
| Source | `PRODUCTS` | Table | Product catalog |
| Source | `SALES_ORDERS` | Table | Order headers |
| Source | `ORDER_LINE_ITEMS` | Table | Order detail lines |
| Analytics | `DT_CUSTOMER_ORDERS_SUMMARY` | Dynamic Table | Per-customer aggregates |
| Analytics | `DT_PRODUCT_SALES_METRICS` | Dynamic Table | Per-product aggregates |
| Analytics | `DT_DAILY_SALES_AGG` | Dynamic Table | Daily business metrics |
| Serve | `VW_CUSTOMER_360` | View | Customer profile + segmentation |
| Serve | `VW_PRODUCT_PERFORMANCE` | View | Product KPIs + performance tier |
| Procedures | `CANCEL_CUSTOMER_ORDERS` | Stored Procedure | Cancels all orders for a given customer |

**Total: 15 objects**

## Project Structure

```
retail-sales-project/
├── manifest.yml                    # Targets, templating, project config
└── sources/
    └── definitions/
        ├── infrastructure.sql      # Database, schemas, warehouse
        ├── tables.sql              # Source tables (RAW)
        ├── analytics.sql           # Dynamic tables (transformations)
        ├── serve.sql               # Views (consumption)
        └── procedures.sql          # Stored procedures
```

## Prerequisites

### Tools
- Snowflake CLI (`snow`) version 3.17+
- A Snowflake account with appropriate privileges

### Snowflake Setup (one-time per environment)

The DCM project cannot define its own parent database/schema. Create these manually before first deploy:

```sql
-- Create project container (replace <ENV> with DEV/STG/PROD)
CREATE DATABASE IF NOT EXISTS RETAIL_DB_<ENV>;
CREATE SCHEMA IF NOT EXISTS RETAIL_DB_<ENV>.DCM_PROJECTS;

-- Create and configure the deployment role
CREATE ROLE IF NOT EXISTS ENGINEERING_<ENV>;
GRANT USAGE ON DATABASE RETAIL_DB_<ENV> TO ROLE ENGINEERING_<ENV>;
GRANT USAGE ON SCHEMA RETAIL_DB_<ENV>.DCM_PROJECTS TO ROLE ENGINEERING_<ENV>;
GRANT CREATE DCM PROJECT ON SCHEMA RETAIL_DB_<ENV>.DCM_PROJECTS TO ROLE ENGINEERING_<ENV>;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE ENGINEERING_<ENV>;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE ENGINEERING_<ENV>;
GRANT ROLE ENGINEERING_<ENV> TO USER <YOUR_USER>;
```

## Usage

### 1. Register the DCM Project (one-time)

```bash
snow dcm create RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV -c <connection>
```

### 2. Validate Definitions

```bash
snow dcm raw-analyze RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV \
  -c <connection> --target DEV
```

### 3. Preview Changes (Plan)

```bash
snow dcm plan RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV \
  -c <connection> --target DEV
```

### 4. Deploy

```bash
snow dcm deploy RETAIL_DB_DEV.DCM_PROJECTS.RETAIL_SALES_DEV \
  -c <connection> --target DEV --alias "description_of_change"
```

### 5. Deploy to Other Environments

```bash
# Staging
snow dcm deploy RETAIL_DB_STG.DCM_PROJECTS.RETAIL_SALES_STG \
  -c <connection> --target STG --alias "promote_to_stg"

# Production
snow dcm deploy RETAIL_DB_PROD.DCM_PROJECTS.RETAIL_SALES_PROD \
  -c <connection> --target PROD --alias "release_v1"
```

## Multi-Environment Configuration

| Target | Database | Warehouse | DT Refresh Lag | Retention |
|--------|----------|-----------|----------------|-----------|
| DEV | `RETAIL_DATA_DEV` | XSMALL | 1 hour | 1 day |
| STG | `RETAIL_DATA_STG` | SMALL | 30 minutes | 1 day |
| PROD | `RETAIL_DATA_PROD` | MEDIUM | 5 minutes | 1 day |

All environment differences are handled via Jinja templating in `manifest.yml` — no code duplication.

## Role Hierarchy

```
ACCOUNTADMIN
├── ENGINEERING_PROD    (deploys to PROD — CI/CD only, restricted)
├── ENGINEERING_STG     (deploys to STG — CI/CD or senior devs)
└── ENGINEERING_DEV     (deploys to DEV — all developers)
```

Each role only has privileges on its respective environment's project and databases.

---

## Best Practices for Snowflake DCM Projects

### Project Organization

1. **Separate project container from managed objects** — Register the DCM project in a dedicated database/schema (e.g., `ADMIN_DB.DCM_PROJECTS`) so you can freely DEFINE all data databases without hitting the parent constraint.

2. **One project per domain** — Keep projects scoped to a business domain (sales, marketing, finance). Avoid monolithic projects that manage everything.

3. **Flat file structure** — Use a flat `sources/definitions/` layout grouped by purpose (`tables.sql`, `analytics.sql`). Only nest into subdirectories for very large projects (50+ objects).

4. **Meaningful file names** — Name files by layer or domain, not by object type abbreviations. `tables.sql` > `tbl.sql`.

### Definition Writing

5. **Always use fully qualified names** — `DATABASE.SCHEMA.OBJECT`, never unqualified.

6. **Enable CHANGE_TRACKING on source tables** — Required for dynamic tables to detect changes incrementally.

7. **Use INITIALIZE = 'ON_CREATE' for dynamic tables** — Populates data immediately on deploy so you can verify correctness.

8. **Use `WITH MANAGED ACCESS` on governed schemas** — Centralizes privilege management on schemas containing sensitive data.

9. **Use comments on objects** — They cost nothing and help discoverability via `SHOW` commands and Snowsight.

### Templating

10. **Template everything that differs between environments** — Database names, warehouse sizes, retention, refresh lags. Never hardcode environment-specific values.

11. **Keep templating variables minimal** — Only parameterize what actually changes. Don't over-abstract.

12. **Use `defaults` in manifest** — Set sensible defaults that work for DEV, override only what's needed in STG/PROD configs.

### Deployment Safety

13. **Always run `plan` before `deploy`** — Review CREATE/ALTER/DROP operations before applying. Never blind-deploy.

14. **Use `--alias` on every deploy** — Provides an audit trail of what was deployed and why.

15. **Watch for DROP operations** — If plan shows unexpected DROPs, investigate. Removing a DEFINE statement causes the object to be dropped.

16. **Use least-privilege roles** — Never deploy with ACCOUNTADMIN. Create dedicated deployment roles per environment.

### Multi-Environment Promotion

17. **Unique `project_name` per target on the same account** — Use suffixes (`_DEV`, `_STG`, `_PROD`) to prevent targets from overwriting each other.

18. **Promote code, not state** — Merge changes to your main branch, then deploy to each target. Don't copy Snowflake state between environments.

19. **Gate PROD deploys** — Use CI/CD pipelines with approval gates for production deployments.

### Maintenance

20. **Run `raw-analyze` during development** — Catches syntax errors, missing dependencies, and circular references before you hit plan/deploy.

21. **Don't modify DCM-managed objects outside DCM** — Manual `ALTER` commands create drift. DCM will reconcile on next deploy which may cause unexpected changes.

22. **Use `snow dcm purge` carefully** — It permanently drops all managed objects and data. Only use for complete teardowns.

23. **Version control your project** — Treat `manifest.yml` and `sources/` as code. Use git, PRs, and code review.

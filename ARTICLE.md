# Snowflake DCM Projects: Infrastructure as Code for Snowflake

> **Status**: Preview Feature — Available in AWS, Azure, and GCP commercial regions.
>
> **Reference**: [Snowflake DCM Projects Documentation](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-overview)

---

## Table of Contents

1. [What is a DCM Project?](#what-is-a-dcm-project)
2. [The DCM Project Object](#the-dcm-project-object)
3. [DCM Project Lifecycle](#dcm-project-lifecycle)
4. [Project File Structure](#project-file-structure)
5. [Supported Object Types](#supported-object-types)
6. [Multi-Environment Deployment](#multi-environment-deployment)
7. [How DCM Detects Changes](#how-dcm-detects-changes)
8. [Practical Example: Retail Sales Pipeline](#practical-example-retail-sales-pipeline)
9. [Command Reference](#command-reference)
10. [Key Constraints and Considerations](#key-constraints-and-considerations)
11. [Interface Options](#interface-options)
12. [CI/CD Integration](#cicd-integration)
13. [Summary](#summary)
14. [Further Reading](#further-reading)

---

## What is a DCM Project?

A **DCM Project** (Database Change Management Project) is Snowflake's native infrastructure-as-code solution. It enables a **declarative approach** to managing Snowflake objects — you define the desired state of your environment, and Snowflake determines and applies the necessary changes to reach that state.

Instead of writing imperative scripts that say *how* to change things step-by-step, you declare *what* should exist. Snowflake handles the sequencing, dependency resolution, and change detection automatically.

### The Core Principle: Declarative over Imperative

```sql
-- IMPERATIVE (traditional): You manage the "how"
CREATE TABLE IF NOT EXISTS my_db.raw.customers (id NUMBER);
ALTER TABLE my_db.raw.customers ADD COLUMN email VARCHAR(255);
ALTER TABLE my_db.raw.customers ADD COLUMN phone VARCHAR(20);

-- DECLARATIVE (DCM): You declare the "what"
DEFINE TABLE my_db.raw.customers (
    id NUMBER,
    email VARCHAR(255),
    phone VARCHAR(20)
);
```

With DCM, there is no `ALTER`. You modify the definition, and DCM figures out what changed.

---

## The DCM Project Object

A DCM Project Object is a **schema-level object in Snowflake** — similar to a table or a view, but it serves a different purpose. It is the deployment engine and audit store for your infrastructure definitions.

```
┌─────────────────────────────────────────────────────────────┐
│              DCM Project Object                              │
│              (Schema-Level Object)                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  • Receives definition files during PLAN and DEPLOY         │
│  • Compares definitions against live Snowflake state        │
│  • Determines CREATE / ALTER / DROP operations              │
│  • Stores immutable deployment history and artifacts        │
│  • Can manage objects in ANY database (not just its own)    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Key Characteristics

| Property | Description |
|----------|-------------|
| **Location** | Lives in a database.schema (e.g., `ADMIN_DB.DCM.MY_PROJECT`) |
| **Scope** | Can manage objects across multiple databases — not limited to its parent |
| **Constraint** | Cannot define its own parent database or schema |
| **One per environment** | Each target (DEV, STG, PROD) needs its own project object |
| **Audit trail** | Stores all deployment history with artifacts |

### Creating a DCM Project Object

```sql
-- SQL
CREATE DCM PROJECT my_db.my_schema.my_project;

-- Snowflake CLI
snow dcm create my_db.my_schema.my_project -c <connection>
```

**Required privilege:**
```sql
GRANT CREATE DCM PROJECT ON SCHEMA my_db.my_schema TO ROLE my_role;
```

> **Reference**: [Supported object types in DCM Projects](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-supported-entities)

---

## DCM Project Lifecycle

The lifecycle follows a structured, repeatable pattern — similar to Terraform's init → plan → apply workflow.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DCM PROJECT LIFECYCLE                                 │
└─────────────────────────────────────────────────────────────────────────────┘

  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌─────────┐
  │  AUTHOR  │───▶│  CREATE  │───▶│   PLAN   │───▶│  DEPLOY  │───▶│ MONITOR │
  │          │    │          │    │          │    │          │    │         │
  │ Write    │    │ Register │    │ Dry-run  │    │ Apply    │    │ Audit & │
  │ DEFINE   │    │ project  │    │ preview  │    │ changes  │    │ iterate │
  │ files    │    │ object   │    │ changes  │    │ to live  │    │         │
  └──────────┘    └──────────┘    └──────────┘    └──────────┘    └─────────┘
       │                                                                │
       └────────────────────────── ITERATE ─────────────────────────────┘
```

### Phase 1: Author

Write definition files using `DEFINE` statements. These are SQL files with a declarative twist:

```sql
DEFINE DATABASE analytics_db;
DEFINE SCHEMA analytics_db.raw;
DEFINE TABLE analytics_db.raw.events (
    event_id NUMBER NOT NULL,
    event_type VARCHAR(50),
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CHANGE_TRACKING = TRUE;
```

**Rules:**
- All objects use **fully qualified names** (`database.schema.object`)
- Order of DEFINE statements does not matter — Snowflake resolves dependencies
- Removing a DEFINE statement causes the object to be **dropped** on next deploy

### Phase 2: Create

Register the DCM project object in Snowflake (one-time per environment):

```bash
snow dcm create MY_DB.MY_SCHEMA.MY_PROJECT -c <connection>
```

### Phase 3: Plan

Preview what will change — without modifying anything:

```bash
snow dcm plan MY_DB.MY_SCHEMA.MY_PROJECT -c <connection> --target DEV
```

Output:
```
CREATE   DATABASE    ANALYTICS_DB
CREATE   SCHEMA      ANALYTICS_DB.RAW
CREATE   TABLE       ANALYTICS_DB.RAW.EVENTS

Planned 3 entities (3 to create, 0 to alter, 0 to drop)
```

### Phase 4: Deploy

Apply the changes:

```bash
snow dcm deploy MY_DB.MY_SCHEMA.MY_PROJECT -c <connection> --target DEV --alias "v1.0"
```

### Phase 5: Monitor & Iterate

```bash
# View deployment history
snow dcm list-deployments MY_DB.MY_SCHEMA.MY_PROJECT -c <connection>

# Make changes to definitions, then repeat: plan → deploy
```

> **Reference**: [Deploy and manage DCM Projects](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-use)

---

## Project File Structure

A DCM project consists of a manifest file and definition files:

```
my-project/
├── manifest.yml                # Project configuration and targets
└── sources/
    └── definitions/
        ├── infrastructure.sql  # Databases, schemas, warehouses
        ├── tables.sql          # Table definitions
        ├── analytics.sql       # Dynamic tables
        ├── serve.sql           # Views
        ├── access.sql          # Roles and grants
        └── procedures.sql      # Stored procedures
```

### The Manifest (`manifest.yml`)

The manifest defines **targets** (environments) and **templating variables**:

```yaml
manifest_version: 2
type: DCM_PROJECT
default_target: 'DEV'

targets:
  DEV:
    account_identifier: <YOUR_ACCOUNT>
    project_name: 'ADMIN_DB.DCM.MY_PROJECT_DEV'
    project_owner: ENGINEERING_DEV
    templating_config: 'DEV'
  PROD:
    account_identifier: <YOUR_ACCOUNT>
    project_name: 'ADMIN_DB.DCM.MY_PROJECT_PROD'
    project_owner: ENGINEERING_PROD
    templating_config: 'PROD'

templating:
  defaults:
    env_suffix: '_DEV'
    wh_size: 'XSMALL'
  configurations:
    DEV:
      env_suffix: '_DEV'
      wh_size: 'XSMALL'
    PROD:
      env_suffix: '_PROD'
      wh_size: 'LARGE'
```

---

## Supported Object Types

DCM supports the following Snowflake objects via the `DEFINE` statement:

| Object Type | Keyword | Notes |
|-------------|---------|-------|
| Database | `DEFINE DATABASE` | Cannot rename after creation |
| Schema | `DEFINE SCHEMA` | Supports `WITH MANAGED ACCESS` |
| Table | `DEFINE TABLE` | Supports `CHANGE_TRACKING`, column add/drop |
| View | `DEFINE VIEW` | Secure views supported |
| Dynamic Table | `DEFINE DYNAMIC TABLE` | Requires `WAREHOUSE` and `TARGET_LAG` |
| Task | `DEFINE TASK` | Auto suspend/resume during deploy |
| Alert | `DEFINE ALERT` | Auto suspend/resume during deploy |
| Warehouse | `DEFINE WAREHOUSE` | Uses `WITH` clause |
| Role | `DEFINE ROLE` | Account-wide scope |
| Database Role | `DEFINE DATABASE ROLE` | Database-scoped |
| Stage (Internal) | `DEFINE STAGE` | External stages also supported |
| File Format | `DEFINE FILE FORMAT` | TYPE is immutable |
| Sequence | `DEFINE SEQUENCE` | START is immutable |
| SQL Procedure | `DEFINE PROCEDURE` | Signature is immutable |
| SQL Function | `DEFINE FUNCTION` | No auto dependency sorting |
| Tag | `DEFINE TAG` | Cannot attach to objects via DCM |
| Auth Policy | `DEFINE AUTHENTICATION POLICY` | PAT policies |

**Imperative statements** (not DEFINE):
- `GRANT ... TO ROLE ...` — Standard SQL grant syntax
- `ATTACH DATA METRIC FUNCTION` — Data quality expectations

> **Reference**: [Supported object types](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-supported-entities)

---

## Multi-Environment Deployment

DCM is designed for promoting code across environments. One codebase, multiple targets:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ONE CODEBASE (Git Repository)                         │
│                                                                         │
│   manifest.yml + sources/definitions/*.sql                              │
└────────────┬────────────────────┬────────────────────┬──────────────────┘
             │                    │                    │
             ▼                    ▼                    ▼
   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
   │   --target DEV   │ │   --target STG   │ │  --target PROD   │
   │                  │ │                  │ │                  │
   │ Project Object:  │ │ Project Object:  │ │ Project Object:  │
   │ MY_PROJECT_DEV   │ │ MY_PROJECT_STG   │ │ MY_PROJECT_PROD  │
   │                  │ │                  │ │                  │
   │ WH: XSMALL       │ │ WH: SMALL        │ │ WH: LARGE        │
   │ Lag: 1 hour      │ │ Lag: 30 min      │ │ Lag: 5 min       │
   └──────────────────┘ └──────────────────┘ └──────────────────┘
```

### How Jinja Templating Enables This

Definition files use `{{ variables }}` that resolve differently per environment:

```sql
DEFINE DATABASE SALES_DATA{{env_suffix}};

DEFINE WAREHOUSE SALES_WH{{env_suffix}}
WITH WAREHOUSE_SIZE = '{{wh_size}}';
```

When deployed with `--target DEV`, this renders as:
```sql
DEFINE DATABASE SALES_DATA_DEV;
DEFINE WAREHOUSE SALES_WH_DEV WITH WAREHOUSE_SIZE = 'XSMALL';
```

When deployed with `--target PROD`:
```sql
DEFINE DATABASE SALES_DATA_PROD;
DEFINE WAREHOUSE SALES_WH_PROD WITH WAREHOUSE_SIZE = 'LARGE';
```

---

## How DCM Detects Changes

DCM compares your local definition files against the **live state** in Snowflake:

```
┌───────────────────────┐         ┌───────────────────────┐
│   LOCAL DEFINITIONS    │         │   LIVE SNOWFLAKE      │
│   (Your .sql files)   │         │   (Current state)     │
├───────────────────────┤         ├───────────────────────┤
│                       │         │                       │
│ DEFINE TABLE foo (    │◄──DIFF──▶ TABLE foo exists with │
│   id NUMBER,         │         │   id NUMBER           │
│   name VARCHAR,      │         │                       │
│   email VARCHAR ←NEW │         │   (no email column)   │
│ );                   │         │                       │
│                       │         │                       │
└───────────────────────┘         └───────────────────────┘
                    │
                    ▼
            ┌──────────────┐
            │ PLAN OUTPUT  │
            │              │
            │ ALTER TABLE  │
            │ foo          │
            │ (add email)  │
            └──────────────┘
```

| Scenario | DCM Action |
|----------|------------|
| New DEFINE statement | **CREATE** the object |
| DEFINE changed vs live state | **ALTER** the object |
| DEFINE removed from files | **DROP** the object |
| DEFINE matches live state | **No action** (skipped) |

---

## Practical Example: Retail Sales Pipeline

Here's a concise, real-world example demonstrating all concepts together.

### Infrastructure

```sql
-- sources/definitions/infrastructure.sql
DEFINE DATABASE RETAIL_DATA{{env_suffix}};

DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.RAW;
DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.ANALYTICS WITH MANAGED ACCESS;
DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.SERVE WITH MANAGED ACCESS;

DEFINE WAREHOUSE RETAIL_WH{{env_suffix}}
WITH WAREHOUSE_SIZE = '{{wh_size}}' AUTO_SUSPEND = 300 AUTO_RESUME = TRUE;
```

### Source Tables

```sql
-- sources/definitions/tables.sql
DEFINE TABLE RETAIL_DATA{{env_suffix}}.RAW.CUSTOMERS (
    CUSTOMER_ID NUMBER NOT NULL,
    FIRST_NAME VARCHAR(100),
    LAST_NAME VARCHAR(100),
    EMAIL VARCHAR(255),
    SIGNUP_DATE DATE
)
CHANGE_TRACKING = TRUE;

DEFINE TABLE RETAIL_DATA{{env_suffix}}.RAW.SALES_ORDERS (
    ORDER_ID NUMBER NOT NULL,
    CUSTOMER_ID NUMBER NOT NULL,
    ORDER_DATE DATE,
    TOTAL_AMOUNT NUMBER(12,2),
    STATUS VARCHAR(20) DEFAULT 'PENDING'
)
CHANGE_TRACKING = TRUE;
```

### Dynamic Tables (Auto-Refreshing Transformations)

```sql
-- sources/definitions/analytics.sql
DEFINE DYNAMIC TABLE RETAIL_DATA{{env_suffix}}.ANALYTICS.DT_CUSTOMER_SUMMARY
WAREHOUSE = 'RETAIL_WH{{env_suffix}}'
TARGET_LAG = '{{dt_lag}}'
INITIALIZE = 'ON_CREATE'
AS
SELECT
    c.CUSTOMER_ID,
    c.FIRST_NAME,
    c.LAST_NAME,
    COUNT(DISTINCT o.ORDER_ID) AS TOTAL_ORDERS,
    SUM(o.TOTAL_AMOUNT) AS TOTAL_SPEND
FROM RETAIL_DATA{{env_suffix}}.RAW.CUSTOMERS c
LEFT JOIN RETAIL_DATA{{env_suffix}}.RAW.SALES_ORDERS o
    ON c.CUSTOMER_ID = o.CUSTOMER_ID
GROUP BY c.CUSTOMER_ID, c.FIRST_NAME, c.LAST_NAME;
```

### Deployment

```bash
# Validate → Preview → Apply
snow dcm raw-analyze MY_DB.DCM.RETAIL_SALES_DEV -c <conn> --target DEV
snow dcm plan        MY_DB.DCM.RETAIL_SALES_DEV -c <conn> --target DEV
snow dcm deploy      MY_DB.DCM.RETAIL_SALES_DEV -c <conn> --target DEV --alias "v1.0"
```

---

## Command Reference

| Command | Equivalent | Purpose |
|---------|-----------|---------|
| `snow dcm create` | `terraform init` | Register project object |
| `snow dcm raw-analyze` | `terraform validate` | Syntax and dependency validation |
| `snow dcm plan` | `terraform plan` | Preview CREATE/ALTER/DROP changes |
| `snow dcm deploy` | `terraform apply` | Apply changes to Snowflake |
| `snow dcm list` | — | List all projects in account |
| `snow dcm describe` | `terraform show` | Show project metadata |
| `snow dcm list-deployments` | — | View deployment audit trail |
| `snow dcm preview` | — | Query managed tables/views |
| `snow dcm refresh` | — | Trigger dynamic table refresh |
| `snow dcm test` | — | Run data quality expectations |
| `snow dcm purge` | `terraform destroy` | Drop all managed objects |
| `snow dcm drop` | — | Remove project metadata only |

> **Reference**: [DCM SQL Commands](https://docs.snowflake.com/en/sql-reference/commands-dcm-projects) | [Snowflake CLI DCM](https://docs.snowflake.com/en/developer-guide/snowflake-cli/data-pipelines/dcm-projects)

---

## Key Constraints and Considerations

### What You Must Know

1. **Parent database constraint** — A project cannot DEFINE its own parent database or schema. Place the project object in a separate admin database if you need to define multiple data databases.

2. **Removing a DEFINE = DROP** — If you delete a DEFINE statement that was previously deployed, DCM will **drop that object** (and its data) on next deploy. This is by design but can be dangerous.

3. **Immutable properties** — Some properties cannot be changed after creation (e.g., table renames, procedure signatures, sequence START values). DCM will error if you attempt to modify these.

4. **One project per environment** — Each target environment (DEV, STG, PROD) needs its own project object. Projects on the same account must have **unique names**.

5. **Fully qualified names required** — All objects and references must use `database.schema.object` format.

### Limits

| Limit | Value |
|-------|-------|
| Max entities per project | 20,000 |
| Max total file size | 10 MB |
| Fewer files = faster execution | Consolidate when possible |

---

## Interface Options

| Interface | Best For |
|-----------|----------|
| **Snowsight Workspace** | Browser-based authoring, Git integration, visual plan/deploy |
| **Local IDE + Snowflake CLI** | Engineers who prefer local development, CI/CD pipelines |
| **Cortex Code** | AI-assisted authoring, debugging, and deployment |
| **SQL Commands** | Direct execution from any Snowflake SQL interface |

---

## CI/CD Integration

DCM is designed for automated pipelines. Snowflake provides [reusable GitHub Actions](https://github.com/Snowflake-Labs/snowflake-dcm-projects) for:

- Parsing manifests
- Testing connections
- Running PLAN in pull requests
- Deploying on merge to main

```yaml
# Simplified CI/CD flow
on:
  pull_request:  → snow dcm plan (comment results on PR)
  push (main):   → snow dcm deploy --target PROD --alias "${{ github.sha }}"
```

---

## Summary

| Concept | One-Line Explanation |
|---------|---------------------|
| DCM Project Object | A schema-level Snowflake object that stores and executes your infrastructure definitions |
| DEFINE statement | Declares the desired state of an object — replaces CREATE/ALTER/DROP |
| Manifest | YAML config that maps targets to project objects and templating variables |
| Plan | Dry-run that shows what will change without modifying anything |
| Deploy | Applies the plan — creates, alters, or drops objects to match definitions |
| Target | An environment (DEV/STG/PROD) with its own project object and variable config |
| Templating | Jinja2 variables/loops that make one codebase work across environments |

---

## Further Reading

- [DCM Projects Overview](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-overview)
- [Deploy and Manage DCM Projects](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-use)
- [Supported Object Types](https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-supported-entities)
- [DCM SQL Commands Reference](https://docs.snowflake.com/en/sql-reference/commands-dcm-projects)
- [Snowflake CLI for DCM](https://docs.snowflake.com/en/developer-guide/snowflake-cli/data-pipelines/dcm-projects)
- [Snowflake Labs DCM Repository (Quickstarts & GitHub Actions)](https://github.com/Snowflake-Labs/snowflake-dcm-projects)

---

*Example source code: [github.com/smakireddy/snowflake-dcm-retail-sales](https://github.com/smakireddy/snowflake-dcm-retail-sales)*

-- ============================================================================
-- INFRASTRUCTURE: Database, Schemas, Warehouse
-- Retail Sales Analytics Pipeline
-- ============================================================================

-- Core database for retail data (separate from DCM project container)
DEFINE DATABASE RETAIL_DATA{{env_suffix}}
    COMMENT = 'Retail sales data - {{env_suffix}} environment';

-- RAW schema: landing zone for source data
DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.RAW
    COMMENT = 'Raw source tables from transactional systems'
    DATA_RETENTION_TIME_IN_DAYS = {{retention_days}};

-- ANALYTICS schema: transformation layer (dynamic tables)
DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.ANALYTICS
    WITH MANAGED ACCESS
    COMMENT = 'Aggregated analytics via dynamic tables'
    DATA_RETENTION_TIME_IN_DAYS = {{retention_days}};

-- SERVE schema: consumption layer (views for BI/reporting)
DEFINE SCHEMA RETAIL_DATA{{env_suffix}}.SERVE
    WITH MANAGED ACCESS
    COMMENT = 'Consumption views for dashboards and reporting';

-- Compute warehouse for dynamic table refreshes and queries
DEFINE WAREHOUSE RETAIL_WH{{env_suffix}}
WITH
    WAREHOUSE_SIZE = '{{wh_size}}'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    COMMENT = 'Compute for retail analytics pipeline';

-- ============================================================================
-- SERVE: Consumption views for dashboards and reporting
-- These sit on top of the analytics dynamic tables
-- ============================================================================

-- Customer 360 View: complete customer profile with order history
DEFINE VIEW RETAIL_DATA{{env_suffix}}.SERVE.VW_CUSTOMER_360
AS
SELECT
    cs.CUSTOMER_ID,
    cs.FIRST_NAME,
    cs.LAST_NAME,
    cs.EMAIL,
    cs.CITY,
    cs.STATE,
    cs.TOTAL_ORDERS,
    cs.TOTAL_SPEND,
    cs.AVG_ORDER_VALUE,
    cs.FIRST_ORDER_DATE,
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

-- Product Performance View: product catalog enriched with sales KPIs
DEFINE VIEW RETAIL_DATA{{env_suffix}}.SERVE.VW_PRODUCT_PERFORMANCE
AS
SELECT
    pm.PRODUCT_ID,
    pm.PRODUCT_NAME,
    pm.CATEGORY,
    pm.SUBCATEGORY,
    pm.CATALOG_PRICE,
    pm.TOTAL_UNITS_SOLD,
    pm.TOTAL_REVENUE,
    pm.ORDER_COUNT,
    pm.AVG_SELLING_PRICE,
    CASE
        WHEN pm.TOTAL_UNITS_SOLD IS NULL OR pm.TOTAL_UNITS_SOLD = 0 THEN 'NO_SALES'
        WHEN pm.TOTAL_REVENUE >= 10000 THEN 'TOP_PERFORMER'
        WHEN pm.TOTAL_REVENUE >= 1000 THEN 'STEADY'
        ELSE 'LOW_PERFORMER'
    END AS PERFORMANCE_TIER,
    ROUND(pm.AVG_SELLING_PRICE - pm.CATALOG_PRICE, 2) AS PRICE_VARIANCE
FROM RETAIL_DATA{{env_suffix}}.ANALYTICS.DT_PRODUCT_SALES_METRICS pm;

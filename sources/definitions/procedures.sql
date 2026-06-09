-- ============================================================================
-- PROCEDURES: Simple utility stored procedures
-- ============================================================================

-- Resets a customer's order history by marking orders as CANCELLED
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

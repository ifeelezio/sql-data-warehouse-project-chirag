/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
Script Purpose:
    This stored procedure performs the ETL (Extract, Transform, Load) process to 
    populate the 'silver' schema tables from the 'bronze' schema.
	Actions Performed:
		- Truncates Silver tables.
		- Inserts transformed and cleansed data from Bronze into Silver tables.
		
Parameters:
    None. 
	  This stored procedure does not accept any parameters or return any values.

Usage Example:
    EXEC Silver.load_silver;
===============================================================================
*/


CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME; 
    BEGIN TRY
        SET @batch_start_time = GETDATE();
        PRINT '================================================';
        PRINT 'Loading Silver Layer';
        PRINT '================================================';

    		PRINT '------------------------------------------------';
    		PRINT 'Loading CRM Tables';
    		PRINT '------------------------------------------------';

    SET @start_time = GETDATE();
    PRINT '>> Truncating Table: silver.crm_cust_info';

    -- Remove all existing records from the target table
    TRUNCATE TABLE silver.crm_cust_info;

    PRINT '>> Inserting Data Into:silver.crm_cust_info'
    -- Insert cleansed and transformed customer data
    INSERT INTO silver.crm_cust_info (
        cst_id,
        cst_key,
        cst_firstname,
        cst_lastname,
        cst_marital_status,
        cst_gndr,
        cst_create_date
    )

    SELECT
        cst_id,
        cst_key,

        -- Remove leading and trailing spaces from customer names
        TRIM(cst_firstname) AS cst_firstname,
        TRIM(cst_lastname) AS cst_lastname,

        -- Normalize marital status values into readable format
        CASE
            WHEN UPPER(TRIM(cst_marital_status)) = 'S' THEN 'Single'
            WHEN UPPER(TRIM(cst_marital_status)) = 'M' THEN 'Married'
            ELSE 'N/A'
        END AS cst_marital_status,

        -- Normalize gender values into readable format
        CASE
            WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female'
            WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male'
            ELSE 'N/A'
        END AS cst_gndr,

        cst_create_date

    FROM (
        SELECT *,
               -- Assign a row number to each customer record,
               -- ordering by the most recent creation date
               ROW_NUMBER() OVER (
                   PARTITION BY cst_id
                   ORDER BY cst_create_date DESC
               ) AS flag_last
        FROM bronze.crm_cust_info
    ) AS t

    -- Keep only the latest record for each customer
    WHERE flag_last = 1;
    SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

    --------------------------------------------------------------------------------------------------------------
    SET @start_time = GETDATE();
    PRINT '>> Truncating Table: silver.crm_prd_info';

    -- Remove all existing records from the target table
    TRUNCATE TABLE silver.crm_prd_info;

    PRINT '>> Inserting Data Into:silver.crm_prd_info'
    -- Insert cleansed and transformed product data
    INSERT INTO silver.crm_prd_info (
        prd_id,
        cat_id,
        prd_key,
        prd_nm,
        prd_cost,
        prd_line,
        prd_start_dt,
        prd_end_dt
    )
    SELECT
        prd_id,

        -- Extract Category ID from the product key
        -- Example: 'AC-HE-HL-U509-R' → 'AC_HE'
        REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_') AS cat_id,

        -- Extract the Product Key by removing the category prefix
        -- Example: 'AC-HE-HL-U509-R' → 'HL-U509-R'
        SUBSTRING(prd_key, 7, LEN(prd_key)) AS prd_key,

        prd_nm,

        -- Replace NULL product costs with 0
        ISNULL(prd_cost, 0) AS prd_cost,

        -- Normalize product line codes into descriptive values
        CASE UPPER(TRIM(prd_line))
            WHEN 'M' THEN 'Mountain'
            WHEN 'R' THEN 'Road'
            WHEN 'S' THEN 'Other Sales'
            WHEN 'T' THEN 'Touring'
            ELSE 'N/A'
        END AS prd_line,

        -- Convert product start date to DATE format
        CAST(prd_start_dt AS DATE) AS prd_start_dt,

        -- Calculate the product end date as one day before
        -- the next version's start date (Slowly Changing Dimension - Type 2)
        CAST(
            DATEADD(
                DAY,
                -1,
                LEAD(prd_start_dt) OVER (
                    PARTITION BY prd_key
                    ORDER BY prd_start_dt
                )
            ) AS DATE
        ) AS prd_end_dt

    FROM bronze.crm_prd_info;
    SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';


    --------------------------------------------------------------------------------------------------------------
    SET @start_time = GETDATE();
    PRINT '>> Truncating Table: silver.crm_sales_details';

    -- Remove all existing records from the target table
    TRUNCATE TABLE silver.crm_sales_details;
    PRINT '>> Inserting Data Into:silver.crm_sales_details'
    -- Insert cleansed and transformed sales data
    INSERT INTO silver.crm_sales_details (
        sls_ord_num,
        sls_prd_key,
        sls_cust_id,
        sls_order_dt,
        sls_ship_dt,
        sls_due_dt,
        sls_sales,
        sls_quantity,
        sls_price
    )
    SELECT
        sls_ord_num,
        sls_prd_key,
        sls_cust_id,

        -- Convert valid order date to DATE format
        -- Set invalid or missing dates to NULL
        CASE
            WHEN sls_order_dt = 0 OR LEN(sls_order_dt) != 8 THEN NULL
            ELSE CAST(CAST(sls_order_dt AS VARCHAR) AS DATE)
        END AS sls_order_dt,

        -- Convert valid ship date to DATE format
        -- Set invalid or missing dates to NULL
        CASE
            WHEN sls_ship_dt = 0 OR LEN(sls_ship_dt) != 8 THEN NULL
            ELSE CAST(CAST(sls_ship_dt AS VARCHAR) AS DATE)
        END AS sls_ship_dt,

        -- Convert valid due date to DATE format
        -- Set invalid or missing dates to NULL
        CASE
            WHEN sls_due_dt = 0 OR LEN(sls_due_dt) != 8 THEN NULL
            ELSE CAST(CAST(sls_due_dt AS VARCHAR) AS DATE)
        END AS sls_due_dt,

        -- Recalculate sales amount if it is missing,
        -- negative, zero, or does not match Quantity × Price
        CASE
            WHEN sls_sales IS NULL
                 OR sls_sales <= 0
                 OR sls_sales <> sls_quantity * ABS(sls_price)
            THEN sls_quantity * ABS(sls_price)
            ELSE sls_sales
        END AS sls_sales,

        sls_quantity,

        -- Derive unit price if it is missing,
        -- zero, or negative
        CASE
            WHEN sls_price IS NULL
                 OR sls_price <= 0
            THEN sls_sales / NULLIF(sls_quantity, 0)
            ELSE sls_price
        END AS sls_price

    FROM bronze.crm_sales_details;
    SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';


    --------------------------------------------------------------------------------------------------------------

    
PRINT '------------------------------------------------';
PRINT 'Loading ERP Tables'
PRINT '------------------------------------------------';


   SET @start_time = GETDATE();
   PRINT '>> Truncating Table: silver.erp_cust_az12';

    -- Remove all existing records from the target table
    TRUNCATE TABLE silver.erp_cust_az12;
    PRINT '>> Inserting Data Into:silver.erp_cust_az12'
    -- Load transformed data into the silver table
    INSERT INTO silver.erp_cust_az12 (
        cid,
        bdate,
        gen
    )
    SELECT
        -- Remove the 'NAS' prefix from customer IDs
        CASE
            WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid, 4, LEN(cid))
            ELSE cid
        END AS cid,

        -- Set future birthdates to NULL
        CASE
            WHEN bdate > GETDATE() THEN NULL
            ELSE bdate
        END AS bdate,

        -- Standardize gender values
        CASE
            WHEN UPPER(TRIM(gen)) IN ('F', 'FEMALE') THEN 'Female'
            WHEN UPPER(TRIM(gen)) IN ('M', 'MALE') THEN 'Male'
            ELSE 'N/A'
        END AS gen

    FROM bronze.erp_cust_az12;
    SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';


    --------------------------------------------------------------------------------------------------------------
    SET @start_time = GETDATE();
    PRINT '>> Truncating Table: silver.erp_loc_a101';

    -- Remove all existing records from the target table
    TRUNCATE TABLE silver.erp_loc_a101;
    PRINT '>> Inserting Data Into:silver.erp_loc_a101'
    -- Load transformed data into the silver table
    INSERT INTO silver.erp_loc_a101 (
        cid,
        cntry
    )
    SELECT
        -- Remove hyphens from customer IDs
        REPLACE(cid, '-', '') AS cid,

        -- Normalize country values and handle missing data
        CASE
            WHEN TRIM(cntry) = 'DE' THEN 'Germany'
            WHEN TRIM(cntry) IN ('US', 'USA') THEN 'United States'
            WHEN TRIM(cntry) = '' OR cntry IS NULL THEN 'N/A'
            ELSE TRIM(cntry)
        END AS cntry

    FROM bronze.erp_loc_a101;
    SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

    --------------------------------------------------------------------------------------------------------------
    SET @start_time = GETDATE();
    PRINT '>> Truncating Table: silver.erp_px_cat_g1v2';

    -- Remove all existing records from the target table
    TRUNCATE TABLE silver.erp_px_cat_g1v2;
    PRINT '>> Inserting Data Into:silver.erp_px_cat_g1v2'
    -- Load data into the silver table
    INSERT INTO silver.erp_px_cat_g1v2 (
        id,
        cat,
        subcat,
        maintenance
    )
    SELECT
        id,
        cat,
        subcat,
        maintenance
    FROM bronze.erp_px_cat_g1v2;
    SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @batch_end_time = GETDATE();
		PRINT '=========================================='
		PRINT 'Loading Silver Layer is Completed';
        PRINT '   - Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
		PRINT '=========================================='
		
	END TRY
	BEGIN CATCH
		PRINT '=========================================='
		PRINT 'ERROR OCCURED DURING LOADING BRONZE LAYER'
		PRINT 'Error Message' + ERROR_MESSAGE();
		PRINT 'Error Message' + CAST (ERROR_NUMBER() AS NVARCHAR);
		PRINT 'Error Message' + CAST (ERROR_STATE() AS NVARCHAR);
		PRINT '=========================================='
	END CATCH

END

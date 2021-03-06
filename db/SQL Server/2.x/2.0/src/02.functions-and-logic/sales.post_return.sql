﻿IF OBJECT_ID('sales.post_return') IS NOT NULL
DROP PROCEDURE sales.post_return;

GO

CREATE PROCEDURE sales.post_return
(
    @transaction_master_id          bigint,
    @office_id                      integer,
    @user_id                        integer,
    @login_id                       bigint,
    @value_date                     date,
    @book_date                      date,
    @store_id                       integer,
    @counter_id                     integer,
    @customer_id                    integer,
    @price_type_id                  integer,
    @reference_number               national character varying(24),
    @statement_reference            national character varying(2000),
    @details                        sales.sales_detail_type READONLY,
    @tran_master_id                 bigint OUTPUT
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @book_name              national character varying = 'Sales Return';
    DECLARE @cost_center_id         bigint;
    DECLARE @tran_counter           integer;
    DECLARE @tran_code              national character varying(50);
    DECLARE @checkout_id            bigint;
    DECLARE @grand_total            decimal(30, 6);
    DECLARE @discount_total         decimal(30, 6);
    DECLARE @is_credit              bit;
    DECLARE @default_currency_code  national character varying(12);
    DECLARE @cost_of_goods_sold     decimal(30, 6);
    DECLARE @ck_id                  bigint;
    DECLARE @sales_id               bigint;
    DECLARE @tax_total              decimal(30, 6);
    DECLARE @tax_account_id         integer;

    DECLARE @can_post_transaction   bit;
    DECLARE @error_message          national character varying(MAX);

    DECLARE @checkout_details TABLE
    (
        id                              integer IDENTITY PRIMARY KEY,
        checkout_id                     bigint, 
        tran_type                       national character varying(2), 
        store_id                        integer,
        item_id                         integer, 
        quantity                        decimal(30, 6),        
        unit_id                         integer,
        base_quantity                   decimal(30, 6),
        base_unit_id                    integer,                
        price                           decimal(30, 6),
        cost_of_goods_sold              decimal(30, 6) DEFAULT(0),
        discount                        decimal(30, 6) DEFAULT(0),
        discount_rate                   decimal(30, 6),
        tax                             decimal(30, 6),
        shipping_charge                 decimal(30, 6),
        sales_account_id                integer,
        sales_discount_account_id       integer,
        sales_return_account_id         integer,
        inventory_account_id            integer,
        cost_of_goods_sold_account_id   integer
    );

    BEGIN TRY
        DECLARE @tran_count int = @@TRANCOUNT;
        
        IF(@tran_count= 0)
        BEGIN
            BEGIN TRANSACTION
        END;
        
        SELECT
            @can_post_transaction   = can_post_transaction,
            @error_message          = error_message
        FROM finance.can_post_transaction(@login_id, @user_id, @office_id, @book_name, @value_date);

        IF(@can_post_transaction = 0)
        BEGIN
            RAISERROR(@error_message, 10, 1);
            RETURN;
        END;

        SET @tax_account_id                         = finance.get_sales_tax_account_id_by_office_id(@office_id);

        IF(sales.validate_items_for_return(@transaction_master_id, @details) = 0)
        BEGIN
            RETURN 0;
        END;

        SET @default_currency_code          = core.get_currency_code_by_office_id(@office_id);

        SELECT @sales_id = sales.sales.sales_id 
        FROM sales.sales
        WHERE sales.sales.transaction_master_id = +transaction_master_id;
        
        SELECT @cost_center_id = cost_center_id    
        FROM finance.transaction_master 
        WHERE finance.transaction_master.transaction_master_id = @transaction_master_id;

        SELECT 
            @is_credit  = is_credit,
            @ck_id      = checkout_id
        FROM sales.sales
        WHERE transaction_master_id = @transaction_master_id;

            
        INSERT INTO @checkout_details(store_id, item_id, quantity, unit_id, price, discount_rate, tax, shipping_charge)
        SELECT store_id, item_id, quantity, unit_id, price, discount_rate, tax, shipping_charge
        FROM @details;

        UPDATE @checkout_details 
        SET
            tran_type                   = 'Dr',
            base_quantity               = inventory.get_base_quantity_by_unit_id(unit_id, quantity),
            base_unit_id                = inventory.get_root_unit_id(unit_id);

        UPDATE @checkout_details
        SET
            sales_account_id                = inventory.get_sales_account_id(item_id),
            sales_discount_account_id       = inventory.get_sales_discount_account_id(item_id),
            sales_return_account_id         = inventory.get_sales_return_account_id(item_id),        
            inventory_account_id            = inventory.get_inventory_account_id(item_id),
            cost_of_goods_sold_account_id   = inventory.get_cost_of_goods_sold_account_id(item_id);
        
        IF EXISTS
        (
            SELECT TOP 1 0 FROM @checkout_details AS details
            WHERE inventory.is_valid_unit_id(details.unit_id, details.item_id) = 0
        )
        BEGIN
            RAISERROR('Item/unit mismatch.', 10, 1);
        END;


        SET @tran_counter               = finance.get_new_transaction_counter(@value_date);
        SET @tran_code                  = finance.get_transaction_code(@value_date, @office_id, @user_id, @login_id);

        INSERT INTO finance.transaction_master(transaction_counter, transaction_code, book, value_date, book_date, user_id, login_id, office_id, cost_center_id, reference_number, statement_reference)
        SELECT @tran_counter, @tran_code, @book_name, @value_date, @book_date, @user_id, @login_id, @office_id, @cost_center_id, @reference_number, @statement_reference;
        SET @tran_master_id = SCOPE_IDENTITY();
            
        SELECT @tax_total = SUM(COALESCE(tax, 0)) FROM @checkout_details;
        SELECT @discount_total = SUM(COALESCE(discount, 0)) FROM @checkout_details;
        SELECT @grand_total = SUM(COALESCE(price, 0) * COALESCE(quantity, 0)) FROM @checkout_details;



        UPDATE @checkout_details
        SET cost_of_goods_sold = COALESCE(inventory.get_write_off_cost_of_goods_sold(@ck_id, item_id, unit_id, quantity), 0);


        SELECT @cost_of_goods_sold = SUM(cost_of_goods_sold) FROM @checkout_details;


        IF(@cost_of_goods_sold > 0)
        BEGIN
            INSERT INTO finance.transaction_details(transaction_master_id, office_id, value_date, book_date, tran_type, account_id, statement_reference, currency_code, amount_in_currency, er, local_currency_code, amount_in_local_currency)
            SELECT @tran_master_id, @office_id, @value_date, @book_date, 'Dr', inventory_account_id, @statement_reference, @default_currency_code, SUM(COALESCE(cost_of_goods_sold, 0)), 1, @default_currency_code, SUM(COALESCE(cost_of_goods_sold, 0))
            FROM @checkout_details
            GROUP BY inventory_account_id;


            INSERT INTO finance.transaction_details(transaction_master_id, office_id, value_date, book_date, tran_type, account_id, statement_reference, currency_code, amount_in_currency, er, local_currency_code, amount_in_local_currency)
            SELECT @tran_master_id, @office_id, @value_date, @book_date, 'Cr', cost_of_goods_sold_account_id, @statement_reference, @default_currency_code, SUM(COALESCE(cost_of_goods_sold, 0)), 1, @default_currency_code, SUM(COALESCE(cost_of_goods_sold, 0))
            FROM @checkout_details
            GROUP BY cost_of_goods_sold_account_id;
        END;


        INSERT INTO finance.transaction_details(transaction_master_id, office_id, value_date, book_date, tran_type, account_id, statement_reference, currency_code, amount_in_currency, local_currency_code, er,amount_in_local_currency) 
        SELECT @tran_master_id, @office_id, @value_date, @book_date, 'Dr', sales_account_id, @statement_reference, @default_currency_code, SUM(COALESCE(price, 0) * COALESCE(quantity, 0)), @default_currency_code, 1, SUM(COALESCE(price, 0) * COALESCE(quantity, 0))
        FROM @checkout_details
        GROUP BY sales_account_id;


        IF(@discount_total IS NOT NULL AND @discount_total > 0)
        BEGIN
            INSERT INTO finance.transaction_details(office_id, value_date, book_date, tran_type, account_id, statement_reference, currency_code, amount_in_currency, local_currency_code, er, amount_in_local_currency) 
            SELECT @office_id, @value_date, @book_date, 'Cr', sales_discount_account_id, @statement_reference, @default_currency_code, SUM(COALESCE(discount, 0)), @default_currency_code, 1, SUM(COALESCE(discount, 0))
            FROM @checkout_details
            GROUP BY sales_discount_account_id;

            SET @tran_master_id  = SCOPE_IDENTITY();
        END;

        IF(COALESCE(@tax_total, 0) > 0)
        BEGIN
            INSERT INTO finance.transaction_details(transaction_master_id, office_id, value_date, book_date, tran_type, account_id, statement_reference, currency_code, amount_in_currency, local_currency_code, er, amount_in_local_currency) 
            SELECT @tran_master_id, @office_id, @value_date, @book_date, 'Dr', @tax_account_id, @statement_reference, @default_currency_code, @tax_total, @default_currency_code, 1, @tax_total;
        END;    

        IF(@is_credit = 1)
        BEGIN
            INSERT INTO finance.transaction_details(transaction_master_id, office_id, value_date, book_date, tran_type, account_id, statement_reference, currency_code, amount_in_currency, local_currency_code, er, amount_in_local_currency) 
            SELECT @tran_master_id, @office_id, @value_date, @book_date, 'Cr',  inventory.get_account_id_by_customer_id(@customer_id), @statement_reference, @default_currency_code, @grand_total - @discount_total, @default_currency_code, 1, @grand_total - @discount_total;
        END
        ELSE
        BEGIN
            INSERT INTO finance.transaction_details(transaction_master_id, office_id, value_date, book_date, tran_type, account_id, statement_reference, currency_code, amount_in_currency, local_currency_code, er, amount_in_local_currency) 
            SELECT @tran_master_id, @office_id, @value_date, @book_date, 'Cr',  sales_return_account_id, @statement_reference, @default_currency_code, SUM(COALESCE(price, 0) * COALESCE(quantity, 0)) - SUM(COALESCE(discount, 0)), @default_currency_code, 1, SUM(COALESCE(price, 0) * COALESCE(quantity, 0)) - SUM(COALESCE(discount, 0)) + SUM(COALESCE(tax, 0))
            FROM @checkout_details
            GROUP BY sales_return_account_id;
        END;



        INSERT INTO inventory.checkouts(transaction_book, value_date, book_date, transaction_master_id, office_id, posted_by) 
        SELECT @book_name, @value_date, @book_date, @tran_master_id, @office_id, @user_id;
        SET @checkout_id = SCOPE_IDENTITY();

        INSERT INTO inventory.checkout_details(value_date, book_date, checkout_id, transaction_type, store_id, item_id, quantity, unit_id, base_quantity, base_unit_id, price, tax, cost_of_goods_sold, discount)
        SELECT @value_date, @book_date, @checkout_id, tran_type, store_id, item_id, quantity, unit_id, base_quantity, base_unit_id, price, tax, cost_of_goods_sold, discount FROM @checkout_details;

        INSERT INTO sales.returns(sales_id, checkout_id, counter_id, transaction_master_id, return_transaction_master_id, customer_id, price_type_id, is_credit)
        SELECT @sales_id, @checkout_id, @counter_id, @transaction_master_id, @tran_master_id, @customer_id, @price_type_id, 0;

        EXECUTE finance.auto_verify @tran_master_id, @office_id;

        IF(@tran_count = 0)
        BEGIN
            COMMIT TRANSACTION;
        END;
    END TRY
    BEGIN CATCH
        IF(XACT_STATE() <> 0 AND @tran_count = 0) 
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        DECLARE @ErrorMessage national character varying(4000)  = ERROR_MESSAGE();
        DECLARE @ErrorSeverity int                              = ERROR_SEVERITY();
        DECLARE @ErrorState int                                 = ERROR_STATE();
        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH;
END;

GO


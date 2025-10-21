# Shop DB Query Optimization Documentation (written by AI)

## 1\. Overview

This document details the optimization of a slow-running analytics query on the `shop_db` database. The original query was designed to retrieve a comprehensive report on customer activity, including total spending, completed orders, and products/categories purchased.

Due to its reliance on multiple complex, correlated subqueries (especially within the `WHERE` and `ORDER BY` clauses), the query performed poorly (reported runtime: 12 seconds).

The solution involves a **denormalization** strategy by adding a pre-calculated `total_spent` column to the `Customers` table. This, combined with query refactoring using a Common Table Expression (CTE), dramatically improves performance by leveraging an index for filtering and sorting.

## 2\. Database Schema

The database consists of five primary tables:

  * **Customers**: Stores customer profile information.
  * **Categories**: Stores product categories.
  * **Products**: Stores product information, linked to `Categories`.
  * **Orders**: Stores customer order headers, linked to `Customers`.
  * **OrderItems**: Stores individual line items for each order, linked to `Orders` and `Products`.

## 3\. The Problem: Unoptimized Query

The original query was functionally correct but highly inefficient.

### Original Query

```sql
USE shop_db;

# Time: 12 seconds
SELECT c.customer_id,
       c.first_name,
       c.last_name,
       c.email,
       c.city,
       c.registration_date,
       c.is_premium,
       (SELECT SUM(o.total_amount) FROM Orders o WHERE o.customer_id = c.customer_id)                      AS total_spent,
       (SELECT COUNT(*)
        FROM Orders o
        WHERE o.customer_id = c.customer_id
          AND o.status LIKE 'Delivered')                                                                 AS completed_orders,
       (SELECT GROUP_CONCAT(DISTINCT p.product_name SEPARATOR ', ')
        FROM Orders ord
                 JOIN OrderItems oi ON ord.order_id = oi.order_id
                 JOIN Products p ON oi.product_id = p.product_id
        WHERE ord.customer_id = c.customer_id)                                                             AS products_bought,
       (SELECT GROUP_CONCAT(DISTINCT cat.category_name SEPARATOR ', ')
        FROM Orders ord2
                 JOIN OrderItems oi2 ON ord2.order_id = oi2.order_id
                 JOIN Products p2 ON oi2.product_id = p2.product_id
                 JOIN Categories cat ON p2.category_id = cat.category_id
        WHERE ord2.customer_id = c.customer_id)                                                            AS categories_bought
FROM Customers c
WHERE c.registration_date > '2000-01-01'
  AND (SELECT SUM(o.total_amount) FROM Orders o WHERE o.customer_id = c.customer_id) > 1000
  AND EXISTS (SELECT 1
              FROM Orders o3
                       JOIN OrderItems oi3 ON o3.order_id = oi3.order_id
              WHERE o3.customer_id = c.customer_id
                AND oi3.quantity > 1)
ORDER BY (SELECT SUM(o.total_amount) FROM Orders o WHERE o.customer_id = c.customer_id) DESC
LIMIT 10000;
```

### Performance Bottlenecks

1.  **Repetitive Calculations**: The `(SELECT SUM(o.total_amount) ...)` subquery is executed for *every single customer* in the `Customers` table. It's used in the `SELECT` list, the `WHERE` clause, and the `ORDER BY` clause.
2.  **Expensive Sorting**: `ORDER BY (SELECT SUM(...))` is the most significant performance killer. The database cannot use an index for this operation. It must calculate the sum for every row that passes the `WHERE` clause and then sort those results in memory.
3.  **Multiple Joins**: The subqueries for `products_bought` and `categories_bought` independently perform complex joins across `Orders`, `OrderItems`, `Products`, and `Categories` for each customer, reading the same data multiple times.

-----

## 4\. The Solution: Denormalization & Refactoring

The optimization strategy is two-fold:

1.  **Denormalize `total_spent`**: Pre-calculate the total amount spent by each customer and store it directly in the `Customers` table.
2.  **Refactor the Query**: Use the new column for efficient filtering/sorting and use a Common Table Expression (CTE) to consolidate the repeated join logic.

### Step 1: Schema Modification (Denormalization)

First, we add the `total_spent` column, populate it with the calculated values, and create an index on it for fast lookups.

```sql
-- Add the new column to store aggregated data
ALTER TABLE Customers
ADD total_spent DECIMAL(10,2) DEFAULT 0.00;

-- Populate the new column with data from the Orders table
UPDATE Customers c
SET c.total_spent = (
    SELECT COALESCE(SUM(o.total_amount), 0.00)
    FROM Orders o
    WHERE o.customer_id = c.customer_id
);

-- Index the new column for fast filtering and sorting
CREATE INDEX idx_customers_total_spent ON Customers(total_spent);
```

### Step 2: The Optimized Query

The new query leverages the indexed `total_spent` column and a CTE named `OrderDetails` to streamline data retrieval.

```sql
USE shop_db;

-- 1. Use a Common Table Expression (CTE) to gather order details in one pass
WITH OrderDetails AS (
    SELECT 
        ord.customer_id, 
        p.product_name, 
        cat.category_name, 
        oi.quantity > 1 AS is_many
    FROM Orders ord
    JOIN OrderItems oi ON ord.order_id = oi.order_id
    JOIN Products p ON oi.product_id = p.product_id
    JOIN Categories cat ON p.category_id = cat.category_id
)
-- 2. Main query
SELECT /*+ SUBQUERY(MATERIALIZATION) */  -- Optimizer hint to materialize the CTE
       c.customer_id,
       c.first_name,
       c.last_name,
       c.email,
       c.city,
       c.registration_date,
       c.is_premium,
       c.total_spent, -- 3. Select the pre-calculated column (FAST)
       (SELECT COUNT(*)
        FROM Orders o
        WHERE o.customer_id = c.customer_id AND
              o.status LIKE 'Delivered') AS completed_orders,
       (SELECT GROUP_CONCAT(DISTINCT od.product_name SEPARATOR ', ')
        FROM OrderDetails od -- 4. Query the CTE (FAST)
        WHERE od.customer_id = c.customer_id) AS products_bought,
       (SELECT GROUP_CONCAT(DISTINCT od.category_name SEPARATOR ', ')
        FROM OrderDetails od -- 5. Query the CTE again (FAST)
        WHERE od.customer_id = c.customer_id) AS categories_bought
FROM Customers AS c USE INDEX (idx_customers_total_spent) -- 6. Hint to use the new index
WHERE c.registration_date > '2000-01-01'
  AND c.total_spent > 1000 -- 7. Filter on the indexed column (FAST)
  AND EXISTS (SELECT 1 FROM OrderDetails od WHERE od.customer_id = c.customer_id AND od.is_many) -- 8. EXISTS on CTE (FAST)
ORDER BY c.total_spent DESC -- 9. Sort on the indexed column (VERY FAST)
LIMIT 10000;
```

### Key Improvements

  * **Filtering (`WHERE`)**: The check `c.total_spent > 1000` now reads a simple, indexed value instead of calculating a sum for every row.
  * **Sorting (`ORDER BY`)**: The `ORDER BY c.total_spent DESC` clause is now extremely fast as it uses the `idx_customers_total_spent` index.
  * **Consolidated Joins**: The `OrderDetails` CTE performs the expensive joins across four tables *once*. The main query then references this in-memory result multiple times, eliminating redundant join operations.
  * **Clarity**: The query is easier to read and maintain.

-----

## 5\. Maintenance Considerations

**This optimization introduces a new requirement**: The `Customers.total_spent` column is denormalized and will become **stale** as new orders are placed or existing orders are modified.

To keep this data accurate, one of the following methods must be implemented:

1.  **Database Triggers (Recommended)**:

      * Create `AFTER INSERT`, `AFTER UPDATE`, and `AFTER DELETE` triggers on the `Orders` and/or `OrderItems` tables.
      * These triggers would automatically recalculate and update the `Customers.total_spent` value for the affected customer(s) in real-time. This ensures data is always consistent.

2.  **Scheduled Job (Simpler)**:

      * Create a stored procedure that re-runs the `UPDATE Customers ...` script.
      * Use a database event scheduler (like MySQL Event Scheduler) to run this procedure periodically (e.g., every night).
      * This is simpler to implement but means the `total_spent` data may be stale for up to 24 hours.

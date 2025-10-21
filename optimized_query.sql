USE shop_db;

DROP INDEX idx_customers_total_spent ON Customers;
ALTER TABLE Customers DROP COLUMN total_spent;

# Looking at the expert analyze understand that currently the most unoptimized thing is Order By
# It can be optimized only by adding clustered index, but we are ordering by function, which means we need to tune our db to do it

ALTER TABLE Customers
ADD total_spent DECIMAL(10,2) DEFAULT 0.00;

UPDATE Customers c
SET c.total_spent = (
    SELECT COALESCE(SUM(o.total_amount), 0.00)
    FROM Orders o
    WHERE o.customer_id = c.customer_id
);

CREATE INDEX idx_customers_total_spent ON Customers(total_spent);

WITH OrderDetails AS (SELECT customer_id, product_name, category_name, quantity > 1 AS is_many
                      FROM Orders ord
                               JOIN OrderItems oi ON ord.order_id = oi.order_id
                               JOIN Products p ON oi.product_id = p.product_id
                               JOIN Categories cat ON p.category_id = cat.category_id)
SELECT /*+ SUBQUERY(MATERIALIZATION) */  c.customer_id,
       c.first_name,
       c.last_name,
       c.email,
       c.city,
       c.registration_date,
       c.is_premium,
       c.total_spent,
       (SELECT COUNT(*)
        FROM Orders o
        WHERE o.customer_id = c.customer_id AND
              o.status LIKE 'Delivered')                                                                 AS completed_orders,
       (SELECT GROUP_CONCAT(DISTINCT od.product_name SEPARATOR ', ')
        FROM OrderDetails od
        WHERE od.customer_id = c.customer_id)                                                            AS products_bought,
       (SELECT GROUP_CONCAT(DISTINCT od.category_name SEPARATOR ', ')
        FROM OrderDetails od
        WHERE od.customer_id = c.customer_id)
FROM Customers AS c USE INDEX (idx_customers_total_spent)
WHERE c.registration_date > '2000-01-01'
  AND c.total_spent > 1000
  AND EXISTS (SELECT 1 FROM OrderDetails od WHERE od.customer_id = c.customer_id AND od.is_many)
ORDER BY c.total_spent DESC
LIMIT 10000;
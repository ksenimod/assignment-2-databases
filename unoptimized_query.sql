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
CREATE INDEX IF NOT EXISTS idx_orders_date_created ON orders (date_created);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);
CREATE INDEX IF NOT EXISTS idx_order_product_order_id ON order_product (order_id);
CREATE INDEX IF NOT EXISTS idx_order_product_product_id ON order_product (product_id);

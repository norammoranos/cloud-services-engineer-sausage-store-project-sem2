ALTER TABLE order_product
    ADD CONSTRAINT pk_order_product PRIMARY KEY (order_id, product_id);

ALTER TABLE order_product
    ADD CONSTRAINT fk_order_product_order
    FOREIGN KEY (order_id)
    REFERENCES orders (id)
    ON DELETE CASCADE;

ALTER TABLE order_product
    ADD CONSTRAINT fk_order_product_product
    FOREIGN KEY (product_id)
    REFERENCES product (id)
    ON DELETE RESTRICT;

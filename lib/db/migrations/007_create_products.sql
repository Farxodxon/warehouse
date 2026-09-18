CREATE TABLE IF NOT EXISTS products (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL REFERENCES organizations(id),
  category_id INTEGER NOT NULL REFERENCES product_categories(id),
  sku TEXT NOT NULL,
  barcode TEXT,
  name TEXT NOT NULL,
  unit TEXT NOT NULL,
  min_stock NUMERIC,
  max_stock NUMERIC,
  default_shelf_life_days INTEGER,
  attributes JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(organization_id, sku)
);
CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode);
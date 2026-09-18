CREATE TABLE IF NOT EXISTS product_categories (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL REFERENCES organizations(id),
  name TEXT NOT NULL,
  product_type TEXT NOT NULL,
  attribute_schema JSONB NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS zones (
  id SERIAL PRIMARY KEY,
  warehouse_id INTEGER NOT NULL REFERENCES warehouses(id),
  name TEXT NOT NULL,
  zone_type TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
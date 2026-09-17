CREATE TABLE IF NOT EXISTS user_warehouse_access (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  warehouse_id INTEGER NOT NULL REFERENCES warehouses(id),
  role TEXT NOT NULL DEFAULT 'operator',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, warehouse_id)
);
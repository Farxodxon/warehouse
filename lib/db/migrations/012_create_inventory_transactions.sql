CREATE TABLE IF NOT EXISTS inventory_transactions (
  id SERIAL PRIMARY KEY,
  organization_id INTEGER NOT NULL REFERENCES organizations(id),
  type TEXT NOT NULL,
  batch_container_id INTEGER NOT NULL REFERENCES batch_containers(id),
  from_location_id INTEGER REFERENCES storage_locations(id),
  to_location_id INTEGER REFERENCES storage_locations(id),
  quantity NUMERIC NOT NULL,
  performed_by INTEGER NOT NULL REFERENCES users(id),
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS batch_containers (
  id SERIAL PRIMARY KEY,
  batch_id INTEGER NOT NULL REFERENCES batches(id),
  container_barcode TEXT NOT NULL,
  quantity NUMERIC NOT NULL,
  location_id INTEGER REFERENCES storage_locations(id),
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(container_barcode)
);
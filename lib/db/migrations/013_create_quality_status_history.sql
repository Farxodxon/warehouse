CREATE TABLE IF NOT EXISTS quality_status_history (
  id SERIAL PRIMARY KEY,
  batch_id INTEGER NOT NULL REFERENCES batches(id),
  from_status TEXT,
  to_status TEXT NOT NULL,
  note TEXT,
  changed_by INTEGER NOT NULL REFERENCES users(id),
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
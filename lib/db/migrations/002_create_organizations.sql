CREATE TABLE IF NOT EXISTS organizations (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO organizations (name)
SELECT 'Eclair'
WHERE NOT EXISTS (SELECT 1 FROM organizations);
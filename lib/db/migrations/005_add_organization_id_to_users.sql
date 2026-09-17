ALTER TABLE users ADD COLUMN IF NOT EXISTS organization_id INTEGER REFERENCES organizations(id);

UPDATE users SET organization_id = (SELECT id FROM organizations ORDER BY id LIMIT 1)
WHERE organization_id IS NULL;
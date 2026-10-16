ALTER TABLE products ADD COLUMN IF NOT EXISTS default_container_type TEXT;
ALTER TABLE products ADD COLUMN IF NOT EXISTS default_unit_weight_kg NUMERIC;
ALTER TABLE batch_containers ADD COLUMN IF NOT EXISTS unit_weight_kg NUMERIC;

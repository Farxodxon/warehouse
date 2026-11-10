CREATE TABLE IF NOT EXISTS idempotency_keys (
  idem_key TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id),
  method_path TEXT NOT NULL,
  status_code INTEGER NOT NULL DEFAULT 0,
  response_body TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (idem_key, user_id)
);
CREATE INDEX IF NOT EXISTS idx_idempotency_created ON idempotency_keys(created_at);

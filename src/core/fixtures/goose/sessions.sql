PRAGMA journal_mode=WAL;
CREATE TABLE usage_ledger (
  session_id TEXT NOT NULL,
  created_timestamp INTEGER NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens INTEGER NOT NULL DEFAULT 0,
  cost REAL NOT NULL DEFAULT 0,
  cost_source TEXT NOT NULL DEFAULT 'provider',
  is_compaction INTEGER NOT NULL DEFAULT 0
);
INSERT INTO usage_ledger VALUES ('sess-a', 1700000001, 'claude-sonnet-5', 100, 20, 120, 40, 8, 0.0123, 'provider', 0);
INSERT INTO usage_ledger VALUES ('sess-a', 1700000002, 'claude-sonnet-5', 50, 10, 60, 0, 0, 0.005, 'estimated', 0);
INSERT INTO usage_ledger VALUES ('sess-b', 1700000003, 'gpt-5.2', 30, 5, 35, 0, 0, 0.002, 'carried_forward', 0);
INSERT INTO usage_ledger VALUES ('sess-b', 1700000004, 'gpt-5.2', 0, 0, 0, 0, 0, 0.0, 'provider', 0);
INSERT INTO usage_ledger VALUES ('sess-a', 1700000005, 'claude-sonnet-5', 2000, 150, 2150, 0, 0, 0.03, 'provider', 1);

PRAGMA journal_mode=WAL;
CREATE TABLE session (id TEXT PRIMARY KEY, model TEXT);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
INSERT INTO session VALUES ('ks_1', '{"id":"claude-sonnet-5","providerID":"anthropic"}');
INSERT INTO message VALUES ('kmsg_1', 'ks_1', 1700000001000, 1700000001000, '{"role":"assistant","model":{"id":"claude-opus-5","providerID":"anthropic"},"tokens":{"input":100,"output":20,"reasoning":7,"cache":{"read":30,"write":4}},"cost":0.01}');
INSERT INTO message VALUES ('kmsg_2', 'ks_1', 1700000002000, 1700000002000, '{"role":"assistant","tokens":{"input":50,"output":10},"cost":0.005}');
INSERT INTO message VALUES ('kmsg_user', 'ks_1', 1700000003000, 1700000003000, '{"role":"user"}');
INSERT INTO message VALUES ('kmsg_bad', 'ks_1', 1700000004000, 1700000004000, '{bad json');

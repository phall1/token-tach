CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
INSERT INTO session VALUES ('ses_next', '/work/next');
INSERT INTO message VALUES ('msg_v1_shadow', 'ses_next', 1000, 1000, '{"role":"assistant","modelID":"gpt-5.4","tokens":{"input":999,"output":999}}');
INSERT INTO session_message VALUES ('msg_next', 'ses_next', 'assistant', 1, 3000, 4000, '{"model":{"id":"claude-sonnet-5","providerID":"anthropic"},"time":{"created":3100,"completed":3900},"tokens":{"input":7,"output":11,"reasoning":2,"cache":{"read":13,"write":17}}}');
INSERT INTO session_message VALUES ('msg_next_user', 'ses_next', 'user', 2, 4001, 4001, '{}');

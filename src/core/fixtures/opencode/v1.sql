CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
INSERT INTO session VALUES ('ses_valid', '/work/project');
INSERT INTO message VALUES ('msg_valid', 'ses_valid', 1000, 2000, '{"role":"assistant","modelID":"gpt-5.4","time":{"created":1100,"completed":1900},"tokens":{"input":10,"output":20,"reasoning":3,"cache":{"read":40,"write":5}}}');
INSERT INTO message VALUES ('msg_bad_json', 'ses_valid', 1000, 2001, '{bad');
INSERT INTO message VALUES ('msg_user', 'ses_valid', 1000, 2002, '{"role":"user"}');

CREATE TABLE IF NOT EXISTS webhooks_raw (
                                            id SERIAL PRIMARY KEY,
                                            received_at TIMESTAMP WITH TIME ZONE NOT NULL,
                                            method TEXT,
                                            path TEXT,
                                            headers JSONB,
                                            body JSONB,
                                            raw_payload JSONB,
                                            status TEXT DEFAULT 'new'
);

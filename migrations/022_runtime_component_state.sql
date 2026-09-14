-- Small durable heartbeat and outcome state for continuously scheduled
-- components. Metrics reads this table; workers update it best-effort.
CREATE TABLE runtime_component_state (
    component TEXT PRIMARY KEY CHECK (component IN (
        'scheduler_tick', 'variant_worker', 'scan'
    )),
    success_count INTEGER NOT NULL DEFAULT 0 CHECK (success_count >= 0),
    failure_count INTEGER NOT NULL DEFAULT 0 CHECK (failure_count >= 0),
    last_started_at TEXT,
    last_success_at TEXT,
    last_failure_at TEXT,
    last_duration_seconds REAL NOT NULL DEFAULT 0 CHECK (last_duration_seconds >= 0),
    last_exit_code INTEGER NOT NULL DEFAULT 0 CHECK (last_exit_code >= 0),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

INSERT INTO runtime_component_state(component)
VALUES ('scheduler_tick'), ('variant_worker'), ('scan');

CREATE INDEX idx_runtime_component_state_success
ON runtime_component_state(last_success_at, component);

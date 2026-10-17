local json = require("dkjson")
local hostname = os.getenv("OVERALLS_LOG_HOSTNAME")
local machine = os.getenv("OVERALLS_LOG_MACHINE")
local environment = os.getenv("OVERALLS_LOG_ENVIRONMENT")
local instance = os.getenv("OVERALLS_LOG_INSTANCE")

local function source(unit, transport)
    if transport == "kernel" then return "kernel" end
    if unit:match("^marshall%-") then return "marshall" end
    if unit == "lilly.service" then return "lilly" end
    if unit == "ziggy.service" then return "ziggy" end
    if unit == "enrico.service" then return "enrico" end
    if unit == "audi.service" or unit:match("^audi%-") then return "audi" end
    if unit == "brady.service" then return "brady" end
    if unit == "galileo.service" then return "galileo" end
    if unit == "underclass.service" then return "underclass" end
    if unit == "brady-storage.service" then return "storage" end
    if unit == "porsche.service" then return "porsche" end
    if unit == "haproxy.service" then return "haproxy" end
    if unit == "overalls-smtprelay.service" then return "mail" end
    if unit:match("^sshd") or unit:match("^sudo") then return "auth" end
    if unit:match("^zfs") or unit:match("^smartd") then return "storage" end
    if unit:match("^overalls%-") or unit:match("^acme%-") or unit:match("^nix%-") then
        return "operations"
    end
    return "system"
end

function normalize(tag, timestamp, record)
    local unit = record._SYSTEMD_UNIT or ""
    local kind = source(unit, record._TRANSPORT)
    if tag == "raw.audit" then kind = "audit" end
    if tag == "raw.firecracker" then kind = "firecracker" end
    local message = record.MESSAGE or record.log or ""
    local payload = message
    if type(message) == "string" then
        local decoded, _, err = json.decode(message)
        if not err and type(decoded) == "table" then payload = decoded end
    end
    local origin = {
        hostname = hostname, machine_id = machine, environment = environment,
        unit = unit, boot_id = record._BOOT_ID,
        invocation_id = record._SYSTEMD_INVOCATION_ID,
        executable = record._EXE, transport = record._TRANSPORT
    }
    if type(record._EXE) == "string" then origin.release = record._EXE:match("^(/nix/store/[^/]+)") end
    if instance and instance ~= "" then origin.instance_id = instance end
    local event = {
        schema_version = 1, source = kind, origin = origin, payload = payload,
        journal_cursor = record.__CURSOR, priority = record.PRIORITY,
        source_file = record.source_file, source_offset = record.source_offset
    }
    -- Correlation is a closed identifier shape, never a payload/header escape.
    local attributes = type(payload) == "table" and (payload.metadata or payload) or nil
    if type(attributes) == "table" then
        for key, size in pairs({ trace_id=32, span_id=16 }) do
            local value = attributes[key]
            if type(value) == "string" and #value == size
               and value:match("^[0-9a-f]+$") and value:match("[1-9a-f]") then
                event[key] = value
            end
        end
    end
    -- A store-facing message: raw text, structured message, or the stable
    -- event name. Capped so journal bursts cannot enlarge payloads unboundedly.
    local text = nil
    if type(payload) == "string" then text = payload
    elseif type(payload) == "table" and type(payload.message) == "string" then text = payload.message
    elseif type(payload) == "table" and type(payload.event) == "string" then text = payload.event end
    if text then event.message = text:sub(1, 8192) end
    -- Platform sources share an output queue while their input shard retains
    -- an explicit source allowlist and at most eight conditional routes.
    local platform = { auth=true, kernel=true, storage=true, mail=true, operations=true, system=true }
    event.route_class = platform[kind] and "platform" or kind
    local summary = type(payload) == "table" and (payload.message or payload) or nil
    local catalog_event = nil
    if type(attributes) == "table" then catalog_event = attributes.event end
    if catalog_event == nil then
        catalog_event = type(payload) == "table" and payload.event or nil
    end
    local flat = type(payload) == "table" and type(payload.metadata) == "table"
      and catalog_event == kind .. ".runtime_metrics"
      and (kind == "marshall" or kind == "lilly" or kind == "porsche")
      and payload.metadata or nil
    local services = { marshall=true, lilly=true, porsche=true, audi=true,
      brady=true, ziggy=true, enrico=true, galileo=true }
    local health_names = { trace_available=true, trace_pending=true,
      trace_queue_dropped=true, trace_export_failed=true, trace_observed_at_seconds=true }
    local health = services[kind] and type(payload) == "table"
      and catalog_event == kind .. ".observability_health"
      and type(payload.metadata) == "table" and payload.metadata or nil
    -- Brady's reviewed formatter writes catalogued fields at the top level.
    -- Only its trusted journal unit and exact health event admit this shape.
    if kind == "brady" and type(payload) == "table" and payload.metadata == nil
       and payload.event == "brady.observability_health" then
        health = payload
    end
    -- Only the trusted Firecracker logging collector (operations) still emits
    -- the closed metrics.summary shape; applications use runtime_metrics.
    local collector = kind == "operations" and type(summary) == "table"
      and summary.event == "metrics.summary" and type(summary.metrics) == "table"
    if collector or flat or health then
        event.metric_service = kind
        event.metrics = {}
        event.metric_present = {}
        for _, name in ipairs(OVERALLS_METRIC_NAMES or {}) do
            local value = nil
            if health then
                if name == "trace_observed_at_seconds" then
                    if type(timestamp) == "table" then value = timestamp.sec end
                elseif health_names[name] then value = health[name] end
            elseif name == "runtime_observed_at_seconds" then
                if type(timestamp) == "table" then value = timestamp.sec end
            elseif not health_names[name] then
                if flat then value = flat[name]
                elseif type(summary) == "table" then value = summary.metrics[name] end
            end
            if flat and name:match("_duration_ms$") then
                local micros = flat[name:gsub("_duration_ms$", "_duration_us")]
                value = type(micros) == "number" and micros / 1000 or nil
            end
            if type(value) == "number" and value >= 0 and value < math.huge
               and (not health or (value < 9223372036854775808
                 and value == math.floor(value)
                 and (name ~= "trace_available" or value <= 1))) then
                event.metrics[name] = value
                event.metric_present[name] = "yes"
            end
        end
    end
    if tag == "raw.firecracker" and type(payload) == "table" and type(payload.event_id) == "string" then
        event.event_id = machine .. ":" .. payload.event_id
    end
    if record.__CURSOR then
        event.event_id = machine .. ":" .. record.__CURSOR
    end
    if event.source == "metrics" then event.route_class = "metrics" end
    return 2, timestamp, event
end

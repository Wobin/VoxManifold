local pcall = pcall
local pairs = pairs
local type = type
local tonumber = tonumber
local tostring = tostring

return function(deps, opts)
    local json = deps.json
    local decode_fn = deps.decode

    local VERSION       = opts.version
    local MAX_BYTES     = opts.max_value_bytes
    local SOFT_BYTES    = opts.soft_value_bytes
    local DECODE_BYTES  = opts.max_decode_bytes
    local MAX_VER_BYTES = opts.max_version_bytes

    local env = {}

    local function clamp_version(mod_version)
        local s = tostring(mod_version)
        if #s > MAX_VER_BYTES then
            return s:sub(1, MAX_VER_BYTES)
        end
        return s
    end

    local function encode_or_nil(value)
        local ok, encoded = pcall(json.encode, value)
        if not ok then
            return nil
        end
        return encoded
    end

    function env.encode_one(mod_version, builder)
        local version_string = clamp_version(mod_version)
        local bare = encode_or_nil({ v = VERSION, m = version_string })

        if not bare then
            return "", "unencodable", 0
        end

        local ok, payload = pcall(builder)
        if not ok or type(payload) ~= "table" then
            return bare, "bare", #bare
        end

        local full = encode_or_nil({ v = VERSION, m = version_string, d = payload })
        if not full then
            return bare, "unencodable", #bare
        end

        local bytes = #full

        if bytes > MAX_BYTES then
            return bare, "shed", bytes
        end

        if bytes > SOFT_BYTES then
            return full, "soft", bytes
        end

        return full, "ok", bytes
    end

    local function parse(raw, limit)
        if type(raw) ~= "string" or raw == "" then
            return nil
        end
        if #raw > limit then
            return nil
        end

        local ok, parsed = pcall(decode_fn, raw)
        if not ok or type(parsed) ~= "table" then
            return nil
        end

        return parsed
    end

    function env.decode(raw)
        local parsed = parse(raw, DECODE_BYTES)
        if not parsed then
            return nil
        end

        local version = tonumber(parsed.v)
        if not version then
            return nil
        end
        if type(parsed.m) ~= "string" then
            return nil
        end

        local data = nil
        if type(parsed.d) == "table" then
            data = parsed.d
        end

        return { version = version, mod_version = parsed.m, data = data }
    end

    function env.advertised(mod_version)
        return { version = VERSION, mod_version = clamp_version(mod_version), data = nil }
    end

    function env.get(decoded)
        if not decoded then
            return nil
        end
        if decoded.data ~= nil then
            return decoded.data
        end
        return false
    end

    function env.decode_v1(raw)
        local parsed = parse(raw, DECODE_BYTES)
        if not parsed then
            return nil
        end

        local version = tonumber(parsed.v)
        if not version then
            return nil
        end
        if type(parsed.c) ~= "table" then
            return nil
        end

        local caps = {}
        for id, ver in pairs(parsed.c) do
            if type(id) == "string" and type(ver) == "string" then
                caps[id] = ver
            end
        end

        local data = {}
        if type(parsed.d) == "table" then
            for id, payload in pairs(parsed.d) do
                if type(id) == "string" and type(payload) == "table" then
                    data[id] = payload
                end
            end
        end

        return { version = version, caps = caps, data = data }
    end

    function env.get_v1(decoded, id)
        if not decoded then
            return nil
        end
        if decoded.caps[id] == nil then
            return nil
        end
        if decoded.data[id] ~= nil then
            return decoded.data[id]
        end
        return false
    end

    return env
end

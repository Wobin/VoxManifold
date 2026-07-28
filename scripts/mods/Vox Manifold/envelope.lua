local pcall = pcall
local pairs = pairs
local type = type
local tonumber = tonumber
local tostring = tostring

return function(deps, opts)
    local json = deps.json
    local decode_fn = deps.decode

    local VERSION = opts.version
    local PER_MOD_BYTES = opts.per_mod_bytes
    local MAX_BYTES = opts.max_bytes

    local env = {}

    function env.encode(reg)
        local caps, data, oversize, dropped = {}, {}, {}, {}
        local ids = reg.ids()

        for i = 1, #ids do
            local id = ids[i]
            local entry = reg.get(id)
            caps[id] = tostring(entry.version)

            local ok, payload = pcall(entry.builder)
            if ok and type(payload) == "table" then
                local encoded = json.encode(payload)
                if not encoded then
                    dropped[#dropped + 1] = id
                else
                    data[id] = payload
                    if #encoded > PER_MOD_BYTES then
                        oversize[id] = #encoded
                    end
                end
            end
        end

        local encoded = json.encode({ v = VERSION, c = caps, d = data })

        return encoded, oversize, dropped
    end

    function env.decode(raw)
        if type(raw) ~= "string" or raw == "" then
            return nil
        end
        if #raw > MAX_BYTES then
            return nil
        end

        local ok, parsed = pcall(decode_fn, raw)
        if not ok or type(parsed) ~= "table" then
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

    function env.get(decoded, id)
        if not decoded then
            return nil
        end
        if decoded.data[id] ~= nil then
            return decoded.data[id]
        end
        if decoded.caps[id] ~= nil then
            return false
        end
        return nil
    end

    return env
end

local pairs = pairs

return function(deps, opts)
    local keys = deps.keys
    local envelope = deps.envelope

    local MAX_BYTES = opts.max_value_bytes

    local published = {}

    local ks = {}

    function ks.build(reg)
        local map, report = {}, {}
        local ids = reg.ids()

        for i = 1, #ids do
            local id = ids[i]
            local entry = reg.get(id)
            local key = keys.key_for(id)

            if key and entry then
                local value, status, bytes = envelope.encode_one(entry.version, entry.builder)

                map[key] = value
                report[#report + 1] = {
                    id     = id,
                    key    = key,
                    status = status,
                    bytes  = bytes,
                }
            end
        end

        for key in pairs(published) do
            if map[key] == nil then
                map[key] = ""
            end
        end

        for _, value in pairs(map) do
            if #value > MAX_BYTES then
                return nil, report
            end
        end

        return map, report
    end

    function ks.commit(map)
        if not map then
            return
        end

        local next_published = {}
        for key, value in pairs(map) do
            if value ~= "" then
                next_published[key] = true
            end
        end

        published = next_published
    end

    function ks.published_count()
        local n = 0
        for _ in pairs(published) do
            n = n + 1
        end
        return n
    end

    return ks
end

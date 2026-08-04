local table_sort = table.sort
local string_format = string.format
local pairs = pairs
local type = type
local tostring = tostring

local ID_PATTERN = "^[a-z0-9_]+%.[a-z0-9_]+$"
local ID_MIN, ID_MAX = 3, 32

return function(opts)
    local VERSION_MAX = opts.max_version_bytes

    local entries = {}
    local count = 0

    local reg = {}

    local function validate_id(id)
        if type(id) ~= "string" then
            return nil, "mod id must be a string"
        end
        if #id < ID_MIN or #id > ID_MAX then
            return nil, string_format("mod id %q must be %d to %d characters", id, ID_MIN, ID_MAX)
        end
        if not id:match(ID_PATTERN) then
            return nil, string_format(
                "mod id %q must be author-scoped as author.name (lowercase [a-z0-9_], one dot)", id)
        end
        return true
    end

    local function validate_version(id, version)
        if type(version) ~= "string" then
            return nil, string_format("mod %q version must be a string", tostring(id))
        end
        if #version > VERSION_MAX then
            return nil, string_format(
                "mod %q version is %d characters; the maximum is %d because it is published on the wire",
                tostring(id), #version, VERSION_MAX)
        end
        return true
    end

    local function validate_builder(id, builder)
        if type(builder) ~= "function" then
            return nil, string_format("mod %q builder must be a function, got %s", tostring(id), type(builder))
        end
        return true
    end

    function reg.register(id, mod_name, version, builder)
        local ok, err = validate_id(id)
        if not ok then
            return nil, err
        end

        local vok, verr = validate_version(id, version)
        if not vok then
            return nil, verr
        end

        local bok, berr = validate_builder(id, builder)
        if not bok then
            return nil, berr
        end

        local existing = entries[id]
        if existing then
            if existing.mod_name ~= mod_name then
                return nil, string_format(
                    "mod id %q already claimed by %q; %q cannot use it",
                    id, tostring(existing.mod_name), tostring(mod_name))
            end
            existing.version = version
            existing.builder = builder
            return true
        end

        entries[id] = {
            id = id,
            mod_name = mod_name,
            version = version,
            builder = builder,
        }
        count = count + 1

        return true
    end

    function reg.unregister(id)
        if not entries[id] then
            return false
        end
        entries[id] = nil
        count = count - 1
        return true
    end

    function reg.get(id)
        return entries[id]
    end

    function reg.ids()
        local ids = {}
        for id in pairs(entries) do
            ids[#ids + 1] = id
        end
        table_sort(ids)
        return ids
    end

    function reg.count()
        return count
    end

    return reg
end

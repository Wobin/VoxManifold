local type = type

local PREFIX = "vm_"

local M = { PREFIX = PREFIX }

function M.key_for(id)
    if type(id) ~= "string" then
        return nil
    end

    local escaped = id:gsub("_", "_u")
    escaped = escaped:gsub("%.", "__")

    return PREFIX .. escaped
end

return M

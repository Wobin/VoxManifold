local pcall = pcall
local pairs = pairs
local type = type
local tostring = tostring

return function(deps)
    local mod = deps.mod
    local managers = deps.managers
    local class = deps.class

    local p = {}
    local reported = {}

    local function report_once(tag, message)
        if reported[tag] then
            return
        end
        reported[tag] = true
        mod:error(message)
    end

    function p.install(get_keys)
        local myself = class and class.PresenceEntryMyself

        if not myself or type(myself.create_key_values) ~= "function" then
            report_once("hook",
                "[Vox Manifold] PresenceEntryMyself.create_key_values is missing. " ..
                "The game has changed; no mod state can be published.")
            return false
        end

        mod:hook(myself, "create_key_values", function(func, self, white_list)
            local ok, key_values = pcall(func, self, white_list)

            if not ok or type(key_values) ~= "table" then
                report_once("hook_call",
                    "[Vox Manifold] create_key_values failed upstream: " .. tostring(key_values) ..
                    ". Publishing mod keys only; engine presence fields are left as they are.")
                key_values = {}
            end

            local keys = get_keys()

            if keys then
                for key, value in pairs(keys) do
                    key_values[key] = value
                end
            end

            return key_values
        end)

        return true
    end

    function p.push(keys)
        local presence = managers and managers.presence

        if not presence or type(presence._update_my_presence) ~= "function" then
            report_once("push",
                "[Vox Manifold] Managers.presence._update_my_presence is missing. " ..
                "The game has changed; mod state cannot be published.")
            return false
        end

        local white_list = {}
        if keys then
            for key in pairs(keys) do
                white_list[key] = true
            end
        end

        local ok, err = pcall(function()
            presence:_update_my_presence(white_list)
        end)

        if not ok then
            report_once("push_err",
                "[Vox Manifold] presence push failed: " .. tostring(err))
            return false
        end

        return true
    end

    local function entry_for(member)
        if not member or type(member.presence) ~= "function" then
            return nil
        end
        local ok, entry = pcall(member.presence, member)
        if not ok or not entry then
            return nil
        end
        return entry
    end

    local function entry_is_myself(entry)
        if type(entry.is_myself) ~= "function" then
            return false
        end
        local ok, res = pcall(entry.is_myself, entry)
        return ok and res == true
    end

    function p.read(member, key)
        local entry = entry_for(member)
        if not entry then
            return nil
        end

        if entry_is_myself(entry) then
            return nil
        end

        if type(entry._key_value_string) ~= "function" then
            report_once("read",
                "[Vox Manifold] presence entry has no _key_value_string. " ..
                "The game has changed; no party member state can be read.")
            return nil
        end

        local ok, raw = pcall(entry._key_value_string, entry, key)
        if not ok then
            return nil
        end

        return raw
    end

    function p.is_myself(member)
        local entry = entry_for(member)
        if not entry then
            return false
        end
        return entry_is_myself(entry)
    end

    function p.members()
        local pim = managers and managers.party_immaterium
        if not pim or type(pim.all_members) ~= "function" then
            return {}
        end
        local ok, members = pcall(pim.all_members, pim)
        if not ok or type(members) ~= "table" then
            return {}
        end

        local out = {}
        for i = 1, #members do
            out[i] = members[i]
        end
        return out
    end

    return p
end

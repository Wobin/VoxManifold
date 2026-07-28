--[[
    Name: Vox Manifold
    Author: Wobin
    Date: 2026-07-15
    Version: 1.0.0
--]]

local mod = get_mod("Vox Manifold")
mod.version = "1.0.0"

local KEY = "dtmods"
local ENVELOPE_VERSION = 1
local MIN_INTERVAL = 2.0

local PER_MOD_SOFT_BYTES = 256

local DECODE_MAX_BYTES = 16384

local BASE = "Vox Manifold/scripts/mods/Vox Manifold/"

local json          = mod:io_dofile(BASE .. "json")
local new_registry  = mod:io_dofile(BASE .. "registry")
local new_envelope  = mod:io_dofile(BASE .. "envelope")
local new_publisher = mod:io_dofile(BASE .. "publisher")
local new_presence  = mod:io_dofile(BASE .. "presence")

local registry = new_registry()

local publisher = new_publisher({ min_interval = MIN_INTERVAL })

local envelope = new_envelope({
    json   = json,
    decode = function(raw) return cjson.decode(raw) end,
}, {
    version       = ENVELOPE_VERSION,
    per_mod_bytes = PER_MOD_SOFT_BYTES,
    max_bytes     = DECODE_MAX_BYTES,
})

local presence = new_presence({
    mod      = mod,
    managers = Managers,
    class    = CLASS,
    key      = KEY,
})

local current_envelope = nil
local read_cache = {}
local listeners = {}
local announced_receive = false
local oversize_reported = {}
local omit_reported = {}

local function debug_on()
    return mod:get("vm_debug") == true
end

local function dbg(fmt, ...)
    if not debug_on() then return end
    mod:info("[Vox Manifold][dbg] " .. (select("#", ...) > 0 and (fmt):format(...) or fmt))
end

local function encode_now()
    if registry.count() == 0 then
        return nil
    end

    local encoded, oversize, dropped = envelope.encode(registry)

    local now_omit = {}
    for i = 1, #dropped do
        local id = dropped[i]
        now_omit[id] = true
        if not omit_reported[id] then
            omit_reported[id] = true
            local entry = registry.get(id)
            mod:error(("[Vox Manifold] %s payload is not encodable and was omitted."):format(
                entry and tostring(entry.mod_name) or id))
        end
    end
    for id in pairs(omit_reported) do
        if not now_omit[id] then
            omit_reported[id] = nil
        end
    end

    local now_over = {}
    for id, bytes in pairs(oversize) do
        now_over[id] = true
        if not oversize_reported[id] then
            oversize_reported[id] = true
            local entry = registry.get(id)
            mod:warning(("[Vox Manifold] %s payload is %d bytes, above the %d-byte efficiency target. Published anyway; consider a leaner payload."):format(
                entry and tostring(entry.mod_name) or id, bytes, PER_MOD_SOFT_BYTES))
        end
    end
    for id in pairs(oversize_reported) do
        if not now_over[id] then
            oversize_reported[id] = nil
        end
    end

    return encoded
end

local function bump()
    read_cache = {}

    local snapshot = {}
    for cb in pairs(listeners) do
        snapshot[#snapshot + 1] = cb
    end

    for i = 1, #snapshot do
        pcall(snapshot[i])
    end
end

local function read_member(member)
    if not member then
        return nil
    end

    local cached = read_cache[member]
    if cached ~= nil then
        return cached or nil
    end

    local raw = presence.read(member)
    local decoded = raw and envelope.decode(raw) or nil

    if decoded and not announced_receive then
        announced_receive = true
        mod:info(("[Vox Manifold] first peer envelope decoded (v%d)"):format(decoded.version))
    end

    if raw and debug_on() then
        local ids = {}
        if decoded then
            for id in pairs(decoded.caps) do ids[#ids + 1] = id end
            table.sort(ids)
        end
        local name = "?"
        pcall(function() name = (member.name and member:name()) or "?" end)
        dbg("read %s: %d bytes -> caps [%s]%s", name, #raw, table.concat(ids, ", "),
            decoded and "" or " DECODE-FAILED")
    end

    read_cache[member] = decoded or false

    return decoded
end

local api = {}
mod.api = api

function api.register(id, owner, builder)
    local version = owner and owner.version or "?"
    local name = (owner and owner.get_name and owner:get_name()) or tostring(id)

    local ok, err = registry.register(id, name, tostring(version), builder)

    if not ok then
        mod:error("[Vox Manifold] " .. tostring(err))
        return nil, err
    end

    mod:info(("[Vox Manifold] registered %s -> %s v%s"):format(id, name, tostring(version)))
    publisher.mark_dirty()

    return true
end

function api.unregister(id)
    local removed = registry.unregister(id)

    if removed then
        publisher.mark_dirty()
    end

    return removed
end

function api.mark_dirty(id)
    if id and not registry.get(id) then
        return false
    end

    publisher.mark_dirty()

    return true
end

function api.get(member, id)
    return envelope.get(read_member(member), id)
end

function api.has_mod(member, id)
    local decoded = read_member(member)
    return decoded and decoded.caps[id] or nil
end

function api.members()
    return presence.members()
end

function api.is_myself(member)
    return presence.is_myself(member)
end

function api.on_update(cb)
    if type(cb) ~= "function" then
        return function() end
    end
    listeners[cb] = true
    return function()
        listeners[cb] = nil
    end
end

function api.registered()
    local out = {}
    local ids = registry.ids()
    for i = 1, #ids do
        local entry = registry.get(ids[i])
        out[ids[i]] = entry and entry.version or nil
    end
    return out
end

function api.my_payload(id)
    local entry = registry.get(id)
    if not entry then
        return nil
    end
    local ok, payload = pcall(entry.builder)
    if ok and type(payload) == "table" then
        return payload
    end
    return nil
end

function api.usage()
    return {
        count = registry.count(),
        bytes = current_envelope and #current_envelope or 0,
    }
end

mod.update = function(dt)
    if registry.count() == 0 then
        return
    end

    local encoded = publisher.update(dt, encode_now)

    if not encoded then
        return
    end

    current_envelope = encoded

    if presence.push() then
        mod:info(("[Vox Manifold] published envelope: %d mods, %d bytes"):format(
            registry.count(), #encoded))
        dbg("published: %s", encoded)
    end
end

mod.vm_on_entry = function()
    dbg("event_new_immaterium_entry")
    bump()
end

mod.vm_on_party = function()
    dbg("party_immaterium_other_members_updated")
    publisher.force()
    publisher.mark_dirty()
    bump()
end

mod.on_all_mods_loaded = function()
    local installed = presence.install(function() return current_envelope end)

    Managers.event:register(mod, "event_new_immaterium_entry", "vm_on_entry")
    Managers.event:register(mod, "party_immaterium_other_members_updated", "vm_on_party")

    mod:info(("Vox Manifold v%s loaded (presence key %s, envelope v%d)"):format(
        tostring(mod.version), KEY, ENVELOPE_VERSION))
    dbg("presence hook installed: %s; debug logging ON", tostring(installed))
end

mod.on_setting_changed = function(id)
    if id == "vm_debug" and debug_on() then
        local u = mod.api.usage()
        dbg("debug enabled. consumers=%d, last envelope=%d bytes, key=%s", u.count, u.bytes, KEY)
    end
end

mod.on_unload = function()
    Managers.event:unregister(mod, "event_new_immaterium_entry")
    Managers.event:unregister(mod, "party_immaterium_other_members_updated")
end

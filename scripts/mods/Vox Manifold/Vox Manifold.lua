--[[
    Name: Vox Manifold
    Author: Wobin
    Date: 2026-07-31
    Version: 2.0.0
--]]

local mod = get_mod("Vox Manifold")
mod.version = "2.0.0"

local pairs = pairs
local type = type
local tostring = tostring

local ENVELOPE_VERSION = 2
local MIN_INTERVAL = 2.0

local MAX_VALUE_BYTES = 250
local SOFT_VALUE_BYTES = 200
local DECODE_MAX_BYTES = 16384

local MAX_VERSION_BYTES = 32

local LEGACY_KEY = "dtmods"

local CONSUMER_WARN_AT = 13

local BASE = "Vox Manifold/scripts/mods/Vox Manifold/"

local json          = mod:io_dofile(BASE .. "json")
local keys          = mod:io_dofile(BASE .. "keys")
local new_registry  = mod:io_dofile(BASE .. "registry")
local new_envelope  = mod:io_dofile(BASE .. "envelope")
local new_keyset    = mod:io_dofile(BASE .. "keyset")
local new_publisher = mod:io_dofile(BASE .. "publisher")
local new_presence  = mod:io_dofile(BASE .. "presence")

local registry = new_registry()

local publisher = new_publisher({ min_interval = MIN_INTERVAL })

local envelope = new_envelope({
    json   = json,
    decode = function(raw) return cjson.decode(raw) end,
}, {
    version           = ENVELOPE_VERSION,
    max_value_bytes   = MAX_VALUE_BYTES,
    soft_value_bytes  = SOFT_VALUE_BYTES,
    max_decode_bytes  = DECODE_MAX_BYTES,
    max_version_bytes = MAX_VERSION_BYTES,
})

local keyset = new_keyset({
    keys     = keys,
    envelope = envelope,
}, {
    max_value_bytes = MAX_VALUE_BYTES,
})

local presence = new_presence({
    mod      = mod,
    managers = Managers,
    class    = CLASS,
})

local current_keys = nil
local pending_keys = nil
local last_report = {}
local read_cache = {}
local listeners = {}
local announced_receive = false
local shed_reported = {}
local soft_reported = {}
local count_warned = false
local refused_reported = false

local function debug_on()
    return mod:get("vm_debug") == true
end

local function dbg(fmt, ...)
    if not debug_on() then return end
    mod:info("[Vox Manifold][dbg] " .. (select("#", ...) > 0 and (fmt):format(...) or fmt))
end

local function map_size(map)
    local n = 0
    for _ in pairs(map) do n = n + 1 end
    return n
end

local function report_statuses(report)
    local now_shed, now_soft = {}, {}

    for i = 1, #report do
        local row = report[i]
        local entry = registry.get(row.id)
        local name = entry and tostring(entry.mod_name) or row.id

        if row.status == "shed" then
            now_shed[row.id] = true
            if not shed_reported[row.id] then
                shed_reported[row.id] = true
                mod:error(("[Vox Manifold] %s payload is %d bytes, over the %d-byte backend limit for a single presence value. The payload was dropped; the mod is still advertised. Publish less state."):format(
                    name, row.bytes, MAX_VALUE_BYTES))
            end
        elseif row.status == "unencodable" then
            now_shed[row.id] = true
            if not shed_reported[row.id] then
                shed_reported[row.id] = true
                mod:error(("[Vox Manifold] %s payload is not encodable and was omitted. The mod is still advertised."):format(name))
            end
        elseif row.status == "soft" then
            now_soft[row.id] = true
            if not soft_reported[row.id] then
                soft_reported[row.id] = true
                mod:warning(("[Vox Manifold] %s payload is %d bytes, past the %d-byte comfort line. The hard limit is %d bytes, after which the payload is dropped."):format(
                    name, row.bytes, SOFT_VALUE_BYTES, MAX_VALUE_BYTES))
            end
        end
    end

    for id in pairs(shed_reported) do
        if not now_shed[id] then shed_reported[id] = nil end
    end
    for id in pairs(soft_reported) do
        if not now_soft[id] then soft_reported[id] = nil end
    end
end

local function encode_now()
    if registry.count() == 0 and keyset.published_count() == 0 then
        return nil
    end

    local map, report = keyset.build(registry)
    last_report = report or {}

    if not map then
        if not refused_reported then
            refused_reported = true
            mod:error("[Vox Manifold] refused to publish: a presence value exceeded the " ..
                MAX_VALUE_BYTES .. "-byte limit after shedding. Nothing was sent.")
        end
        return nil
    end

    refused_reported = false

    report_statuses(last_report)

    if map_size(map) == 0 then
        return nil
    end

    pending_keys = map

    return json.encode(map)
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

local function member_cache(member)
    local cache = read_cache[member]
    if not cache then
        cache = {}
        read_cache[member] = cache
    end
    return cache
end

local function read_key(member, key, decode)
    if not member or not key then
        return nil
    end

    local cache = member_cache(member)
    local cached = cache[key]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local raw = presence.read(member, key)
    local decoded = nil
    if raw then
        decoded = decode(raw)
    end

    if decoded and not announced_receive then
        announced_receive = true
        mod:info(("[Vox Manifold] first peer value decoded (v%d)"):format(decoded.version))
    end

    if raw and debug_on() then
        local name = "?"
        pcall(function() name = (member.name and member:name()) or "?" end)
        dbg("read %s [%s]: %d bytes%s", name, key, #raw, decoded and "" or " DECODE-FAILED")
    end

    cache[key] = decoded or false

    return decoded
end

local function read_consumer(member, id)
    local key = keys.key_for(id)
    if not key then
        return nil
    end
    return read_key(member, key, envelope.decode)
end

local function read_legacy(member)
    return read_key(member, LEGACY_KEY, envelope.decode_v1)
end

local api = {}
mod.api = api

function api.register(id, owner, builder)
    if type(owner) ~= "table" then
        local err = ("mod %q owner must be the consumer's mod object (a table), got %s"):format(
            tostring(id), type(owner))
        mod:error("[Vox Manifold] " .. err)
        return nil, err
    end

    local version = owner.version or "?"
    local name = (owner.get_name and owner:get_name()) or tostring(id)

    local ok, err = registry.register(id, name, tostring(version), builder)

    if not ok then
        mod:error("[Vox Manifold] " .. tostring(err))
        return nil, err
    end

    mod:info(("[Vox Manifold] registered %s -> %s v%s (key %s)"):format(
        id, name, tostring(version), tostring(keys.key_for(id))))

    if registry.count() > CONSUMER_WARN_AT and not count_warned then
        count_warned = true
        mod:warning(("[Vox Manifold] %d consumers now hold a presence key each, more than the %d the game itself publishes. Nothing is known to be wrong: the backend's limit on key count is undocumented and untested past this point. Noted here so it is on record if presence misbehaves."):format(
            registry.count(), CONSUMER_WARN_AT))
    end

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
    local decoded = read_consumer(member, id)
    if decoded then
        return envelope.get(decoded)
    end
    return envelope.get_v1(read_legacy(member), id)
end

function api.has_mod(member, id)
    local decoded = read_consumer(member, id)
    if decoded then
        return decoded.mod_version
    end

    local legacy = read_legacy(member)
    if not legacy then
        return nil
    end
    return legacy.caps[id]
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
    local per_mod, total, largest = {}, 0, 0

    for i = 1, #last_report do
        local row = last_report[i]
        per_mod[row.id] = row.bytes
    end

    if current_keys then
        for _, value in pairs(current_keys) do
            total = total + #value
            if #value > largest then
                largest = #value
            end
        end
    end

    return {
        count   = registry.count(),
        bytes   = total,
        largest = largest,
        keys    = per_mod,
        limit   = MAX_VALUE_BYTES,
    }
end

mod.update = function(dt)
    if registry.count() == 0 and current_keys == nil and keyset.published_count() == 0 then
        return
    end

    local token = publisher.update(dt, encode_now)

    if not token then
        return
    end

    current_keys = pending_keys
    keyset.commit(current_keys)

    if presence.push(current_keys) then
        if registry.count() == 0 then
            mod:info("[Vox Manifold] retracted: last consumer gone, cleared its presence key")
        else
            local largest, largest_key = 0, "?"
            for key, value in pairs(current_keys) do
                if #value > largest then
                    largest = #value
                    largest_key = key
                end
            end
            mod:info(("[Vox Manifold] published %d keys; largest is %s at %d of %d bytes"):format(
                map_size(current_keys), largest_key, largest, MAX_VALUE_BYTES))
        end
        dbg("published: %s", token)
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
    local installed = presence.install(function() return current_keys end)

    Managers.event:register(mod, "event_new_immaterium_entry", "vm_on_entry")
    Managers.event:register(mod, "party_immaterium_other_members_updated", "vm_on_party")

    mod:info(("Vox Manifold v%s loaded (key per consumer, prefix %s, envelope v%d, %d-byte limit)"):format(
        tostring(mod.version), keys.PREFIX, ENVELOPE_VERSION, MAX_VALUE_BYTES))
    dbg("presence hook installed: %s; debug logging ON", tostring(installed))
end

mod.on_setting_changed = function(id)
    if id == "vm_debug" and debug_on() then
        local u = mod.api.usage()
        dbg("debug enabled. consumers=%d, largest value=%d of %d per key, %d bytes on the wire in total",
            u.count, u.largest, u.limit, u.bytes)
    end
end

mod.on_unload = function()
    Managers.event:unregister(mod, "event_new_immaterium_entry")
    Managers.event:unregister(mod, "party_immaterium_other_members_updated")
end

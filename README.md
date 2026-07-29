# Vox Manifold

A dependency library for Darktide mods. It replicates small per-player state across a
party by multiplexing each consumer mod's payload into a single Immaterium presence
key. The transport is Fatshark's backend presence service, so there is no peer-to-peer
connection, no NAT traversal, and no signalling. Delivery is server-relayed to every
party member.

Vox Manifold performs no gameplay function on its own. It is inert until a consumer mod
registers.

## Notice about application

Fatshark have been very [nice](https://discord.com/channels/1048312349867646996/1079236027690012773/1164598923386687509)
with regards to generally not policing our usage of mods, 
working on a mutual respect system where we don't rock the boat with specific usage, 
and they don't have to directly intervene. This is especially relevant to cosmetics in
the game. Given that a chunk of their revenue is related to cosmetics and the like, they
would prefer we don't affect it in any way. If they detect any loss in revenue from an 
increased use in a particular mod, they will start banning users using that mod.

So, *be cool about it*. Don't cross that line

## Data model

The channel is last-write-wins replicated state, not a message queue:

- No ordering, history, or delivery guarantee. A rapid sequence of writes may be
  observed only as its final value.
- Broadcast only. A published value is visible to every reader; there is no unicast.
- A client publishes its own state only. Reading another member returns their last
  published value.
- Propagation is sub-second, not real-time. It is suitable for orders, loadouts, and
  status, not for positions or per-frame data.

Presence is readable by any account that holds a member's account id, which is a
superset of the party. Do not publish sensitive data.

## Requirements

A consumer mod must declare the dependency in its `.mod` manifest:

```lua
load_after = { "Vox Manifold" },
require    = { "Vox Manifold" },
```

Acquire the API in `on_all_mods_loaded`. The API is exposed on `mod.api`, not on the
mod object itself:

```lua
local Manifold = get_mod("Vox Manifold")
Manifold = Manifold and Manifold.api
if not Manifold then
    return
end
```

## Mod ids

Each consumer claims a string id in the form `author.name`:

- Pattern `^[a-z0-9_]+%.[a-z0-9_]+$`, length 3 to 32.
- The author segment scopes the id to prevent cross-ecosystem collisions. Two mods that
  publish under the same id corrupt each other's reads across a party, and this cannot
  be detected locally because the two mods run on different machines. Author-scoping is
  the mechanism that avoids it.
- The id is a permanent public identifier. Choose it once and do not change it between
  versions, or old and new builds will not read each other.

## API

```lua
Manifold.register(id, owner, builder)
```
Register a consumer. `owner` is the consumer's mod object; its `version` field is
published in the capability record. `builder` is a function returning the payload table
to publish, or `nil` when there is nothing to publish. The library calls `builder` only
when it needs a fresh payload. Returns `true`, or `nil, error_string` on a rejected id,
or a cross-owner id collision. Re-registering the same id from the
same owner replaces the builder and version, which supports hot reload.

```lua
Manifold.mark_dirty(id)
```
Signal that the consumer's state changed. The library re-runs the builder and publishes
on its own schedule, coalescing and rate-limiting writes. The `id` is validated but not
scoped: there is one multiplexed envelope, so a publish always carries every consumer.
Returns `false` if the id is not registered, which surfaces a typo or a call made before
`register`.

```lua
Manifold.get(member, id) -> table | false | nil
```
Read a member's payload for `id`. Returns the payload table, `false` if the member runs
the mod but has no current payload, or `nil` if the member does not run the mod.

`get` returns `nil` for the local player. A client cannot read back its own published
key; the engine's own presence entry for the local player exposes no read accessor. Use
`is_myself` to branch and supply the local player's row from the consumer's own state.

```lua
Manifold.has_mod(member, id) -> version_string | nil
```
Return the version string a member published for `id`, or `nil` if absent. Sourced from
the capability record, so it is available even when the member has no payload. The string
is `tostring(owner.version)` as the publisher set it; it is opaque. The library does not
parse or compare it. A consumer that gates on version must define and compare its own
format, and must not use a string comparison for numeric version ordering.

```lua
Manifold.members() -> array
```
Return the current party members, including the local player. The returned array is a
copy and is safe to retain.

```lua
Manifold.is_myself(member) -> boolean
```

```lua
Manifold.on_update(callback) -> unsubscribe
```
Register a callback invoked when any member's replicated state may have changed. The
callback is not scoped to a single id; treat it as a signal to re-read the members of
interest. Returns a function that removes the callback. Call it in `on_disabled` or
`on_unload` to avoid a leaked closure across a hot reload.

```lua
Manifold.unregister(id) -> boolean
```
Remove a consumer. On the next publish its capability entry and payload are dropped from
the shared envelope, so peers stop seeing it; when the last consumer unregisters, the
library publishes an empty envelope to retract and then goes dormant. Call this in
`on_disabled` and `on_unload`. A registered consumer that is not unregistered keeps its
capability entry and last payload published.

### Introspection

```lua
Manifold.registered() -> { id = version }
```
The current capability record: every registered id mapped to its version. Read-only.

```lua
Manifold.my_payload(id) -> table | nil
```
The table the consumer's builder currently returns, or `nil`. This runs the builder, so
the builder must remain free of side effects.

```lua
Manifold.usage() -> { count, bytes }
```
Consumer count and the encoded byte length of the last published envelope.

## Example

A complete minimal consumer. The mod shares each player's three curio resistances so the
party can see coverage gaps. It demonstrates the four patterns that a consumer must get
right: registration with a versioned payload, marking dirty on change, reading the party
with the local player special-cased, and teardown.

Manifest, `Curio Coverage.mod`:

```lua
return {
    run = function()
        new_mod("Curio Coverage", {
            mod_script       = "Curio Coverage/scripts/mods/Curio Coverage/Curio Coverage",
            mod_data         = "Curio Coverage/scripts/mods/Curio Coverage/Curio Coverage_data",
            mod_localization = "Curio Coverage/scripts/mods/Curio Coverage/Curio Coverage_localization",
        })
    end,
    load_after = { "Vox Manifold" },
    require    = { "Vox Manifold" },
}
```

Script:

```lua
local mod = get_mod("Curio Coverage")

local ID = "zoze.curios"
local PAYLOAD_VERSION = 1

-- The consumer's own current state, recomputed locally. This is also what the local
-- player's own row is drawn from, because get() cannot read back the local player.
local my_resists = { 0, 0, 0 }

-- Decode a peer payload, tolerating older and newer payload versions.
local function decode(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local r = payload.r
    if type(r) ~= "table" then
        return nil
    end
    return { tonumber(r[1]) or 0, tonumber(r[2]) or 0, tonumber(r[3]) or 0 }
end

mod.on_all_mods_loaded = function()
    local Manifold = get_mod("Vox Manifold")
    Manifold = Manifold and Manifold.api
    if not Manifold then
        mod:error("Curio Coverage requires Vox Manifold.")
        return
    end
    mod.manifold = Manifold

    Manifold.register(ID, mod, function()
        return { pv = PAYLOAD_VERSION, r = my_resists }
    end)

    -- Re-read and refresh the display whenever any member's state changes.
    mod.manifold_unsub = Manifold.on_update(function()
        mod.refresh_display()
    end)
end

-- Call this from wherever the local player's curios change (an equip hook, etc.).
function mod.recompute_own_resists(a, b, c)
    my_resists = { a, b, c }
    if mod.manifold then
        mod.manifold.mark_dirty(ID)
    end
end

-- Build one row per party member.
function mod.build_rows()
    local Manifold = mod.manifold
    if not Manifold then
        return {}
    end

    local rows = {}
    local members = Manifold.members()
    for i = 1, #members do
        local member = members[i]

        if Manifold.is_myself(member) then
            rows[#rows + 1] = { name = "You", resists = my_resists }
        elseif Manifold.has_mod(member, ID) then
            local resists = decode(Manifold.get(member, ID))
            local name = member.name and member:name() or "?"
            rows[#rows + 1] = { name = name, resists = resists }
        end
    end
    return rows
end

function mod.refresh_display()
    -- redraw from mod.build_rows(); omitted
end

mod.on_disabled = function()
    if mod.manifold then
        mod.manifold.unregister(ID)
    end
    if mod.manifold_unsub then
        mod.manifold_unsub()
    end
end

mod.on_unload = mod.on_disabled
```

Points the example illustrates:

- The payload carries its own `pv`, and `decode` reads defensively so a future `pv = 2`
  payload with extra fields still yields a row.
- The local player is drawn from `my_resists`, not from `get`, because `get` returns
  `nil` for the local player.
- `has_mod` gates the read, so a member who does not run Curio Coverage produces no row.
- `on_disabled` and `on_unload` both unregister the consumer and drop the `on_update`
  callback, so a hot reload does not leak a registration or a closure.

## Payload versioning

Vox Manifold versions the envelope, not the consumer payload. The payload table under a
consumer's id is opaque to the library. A consumer that changes its payload shape
between releases is responsible for its own compatibility: include a version field in
the payload, and have the reader tolerate older and newer shapes. A consumer that omits
this will break its own cross-version reads when users run mixed builds.

## Envelope format

The presence value is a single JSON object:

```json
{ "v": 1, "c": { "author.name": "version" }, "d": { "author.name": { } } }
```

- `v` is the envelope version.
- `c` is the capability record: id to version.
- `d` holds each consumer's payload, keyed by id.

The keys `v`, `c`, and `d` are permanent. A future envelope version may add sibling keys
but must not repurpose these three. A reader ignores an unrecognised envelope version's
additions and reads `c` and `d` on a best-effort basis, so a newer publisher degrades on
an older reader rather than failing.

## Efficiency and limits

Multiplexing keeps the structural footprint constant, not the traffic. Every consumer
shares one presence key, one hook on the presence map, and one coalesced, rate-limited
publish cycle, so adding a mod introduces no new key and no extra network write. The
envelope's size, however, grows with the number of consumers: each adds its own payload
and a capability-record entry. Total traffic therefore scales with adoption, which is why
lean payloads matter.

There is no consumer-count limit and no aggregate byte budget. Every registered consumer
is published.

Efficiency is encouraged, not enforced:

- A per-consumer payload above 256 bytes encoded is published anyway, and the author is
  warned once. Keep payloads small: publish a reference (an id or hash the reader
  resolves locally) rather than a large blob. The presence value is shared party traffic
  on an undocumented backend surface; a lean payload is a courtesy to that surface and to
  the other consumers on the channel.
- A payload that cannot be encoded at all (a function, a cycle) is omitted from the
  envelope and logged as an error, so one broken payload cannot suppress the others. The
  consumer remains advertised in the capability record.

The one hard bound is on the read path: an inbound peer envelope larger than 16384 bytes
is rejected before parsing. This bounds decode cost against a hostile or corrupt peer and
is unrelated to the efficiency target; a legitimately large envelope well under it still
decodes.

## Failure logging

The library logs each publish and the first decode of a peer envelope, and raises a
single error if an engine accessor it depends on is absent. This channel fails silently
at the transport level: if the presence key is rejected server-side, publishing
continues to no effect and peers appear to not run the consumer, with no transport
error. The log lines are the means of diagnosing that condition.

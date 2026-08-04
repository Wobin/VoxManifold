# Vox Manifold

A dependency library for Darktide mods. It replicates small per-player state across a
party by giving each consumer mod its own Immaterium presence key. The transport is
Fatshark's backend presence service, so there is no peer-to-peer connection, no NAT
traversal, and no signalling. Delivery is server-relayed to every party member.

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
when it needs a fresh payload.

Returns `true`, or `nil, error_string`. The error is also logged. Always check it:

```lua
local ok, err = Manifold.register("wobin.havoc", mod, build_payload)
if not ok then
    mod:error("could not register with Vox Manifold: " .. tostring(err))
    return
end
```

Rejections, in the order they are checked, so a call with two problems reports the first:

| Error string | Cause and fix |
| --- | --- |
| `mod "<id>" owner must be the consumer's mod object (a table), got <type>` | You passed something else as `owner`, commonly `nil` or the builder. The owner's identity is what the id-squatting check compares, so a `nil` owner would let any mod claim any id |
| `mod id must be a string` | `id` was not a string |
| `mod id "<id>" must be 3 to 32 characters` | Too short or too long |
| `mod id "<id>" must be author-scoped as author.name (lowercase [a-z0-9_], one dot)` | Not `author.name` form. Rejects uppercase, hyphens, no dot, and more than one dot |
| `mod "<id>" version must be a string` | Your mod's `version` field is not a string, for example the number `2.0` |
| `mod "<id>" version is <n> characters; the maximum is 32 because it is published on the wire` | The version travels inside every value you publish, so an unbounded one could breach the backend's per-value cap on its own |
| `mod "<id>" builder must be a function, got <type>` | You omitted the builder, or called it instead of passing it. Without this check the mod would be advertised to the whole party while structurally unable to ever publish, silently, for the rest of the session |
| `mod id "<id>" already claimed by "<other>"; "<yours>" cannot use it` | Another mod registered that id first. Ids are first-come, which is why they are author-scoped. Choose one under your own prefix |

```lua
Manifold.register("wobin.havoc", nil, build_payload)   -- owner is nil
Manifold.register("wobin.havoc", build_payload)        -- builder in the owner slot
Manifold.register("havoc", mod, build_payload)         -- id not author-scoped
Manifold.register("Wobin.Havoc", mod, build_payload)   -- uppercase
Manifold.register("wobin.havoc", mod)                  -- builder omitted
Manifold.register("wobin.havoc", mod, build_payload()) -- builder called, not passed

Manifold.register("wobin.havoc", mod, build_payload)   -- correct
```

Re-registering the same id from the same owner replaces the builder and version, which
supports hot reload.

```lua
Manifold.mark_dirty(id)
```
Signal that the consumer's state changed. The library re-runs the builder and publishes
on its own schedule, coalescing and rate-limiting writes. The `id` is validated but not
scoped to just that consumer's key: every registered consumer's key is rebuilt and all
of them go out together in one merged update. Returns `false` if the id is not
registered, which surfaces a typo or a call made before `register`.

```lua
Manifold.get(member, id) -> table | false | nil
```
Read a member's payload for `id`. Returns the payload table, `false` if the member runs
the mod but has no current payload, or `nil` if the member does not run the mod.

`get` works for the local player as well as for peers, so a reader can loop over
`members()` uniformly without special-casing itself.

The local player's value is not read back off the wire. A client cannot read its own
published key, because the engine's presence entry for the local player exposes no read
accessor. It is decoded from the bytes the library last published instead, which is the
same thing every peer sees. Two consequences follow. It lags local state by up to the
publish interval of two seconds, so it is not a substitute for the consumer's own live
state. And a payload that was shed for exceeding the byte limit reads back as `false`
here exactly as it does for a peer, which makes an over-budget payload visible locally
rather than only in the log.

Between `register` and the first publish there is nothing published yet, so `get` returns
`false` for the local player during that window.

```lua
Manifold.has_mod(member, id) -> version_string | nil
```
Return the version string a member published for `id`, or `nil` if absent. Sourced from
the capability record, so it is available even when the member has no payload. The string
is `tostring(owner.version)` as the publisher set it; it is opaque. The library does not
parse or compare it. A consumer that gates on version must define and compare its own
format, and must not use a string comparison for numeric version ordering.

Like `get`, this answers for the local player too, reporting the version of a consumer
registered on this client. It answers from the local registry before the first publish,
so it is truthful immediately after `register` rather than after a two-second delay.

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
Manifold.on_update(id, callback) -> unsubscribe
```
Register a callback invoked when any member's replicated state may have changed. The
callback is not scoped to a single id; treat it as a signal to re-read the members of
interest. Returns a function that removes the callback. Call it in `on_disabled` or
`on_unload` to avoid a leaked closure across a hot reload.

The `id` is optional and affects nothing but error reporting. It is not validated against
the registry, does not scope which changes you are told about, and can be passed before
`register`.

Listeners run inside a `pcall`, so one consumer's broken callback cannot stop the others
being notified. That means a callback that throws is skipped rather than propagated, and
the library has to work out whose it was in order to say anything useful about it. Passing
your registered id settles that outright.

Without one, the library infers it: it records where the callback was defined and which
file called `on_update`, then at error time looks for a registered consumer whose mod name
matches that path. A match names that consumer exactly as an explicit id would, so an
existing consumer that never passes an id is still reported correctly.

The inference is deliberately conservative and never names a consumer it cannot match. A
callback built by a shared helper in another mod's folder, or a path matching two
registered consumers at once, both degrade to naming the file rather than blaming the
wrong mod.

It resolves at error time rather than at registration, because a listener can outlive its
registration: a consumer that unregisters in `on_disabled` while keeping its callback is
unattributable until it registers again.

The case inference cannot reach at all is a **read-only consumer**. A mod that only reads
other members and publishes nothing has no reason to call `register`, never enters the
registry, and so can never be matched. Pass the id if you want to be named.

```lua
Manifold.unregister(id) -> boolean
```
Remove a consumer. The backend merges presence key-values rather than replacing them, so
simply ceasing to send a consumer's key would leave its last value in place indefinitely.
To actually clear it, the library overwrites the consumer's own key, `vm_<mod id>`, with
an explicit empty value on the next publish. That write is what removes it.

That empty value is not sent once and forgotten. It keeps riding along on every presence
update the game makes until the next publish rebuilds the key map, at which point the key
is dropped entirely. So the retraction gets many chances to land rather than one.

This matters because a publish reports success when the engine accepted it, not when the
backend received it. A retraction sent while the presence stream is down would otherwise
be lost, and the departed consumer would look present to the whole party.

How long the empty value lingers depends on which consumer left:

| Case | Behaviour |
| --- | --- |
| Other consumers remain | The empty value rides along until the next publish, then the key vanishes from the map |
| The last consumer left | There is no next publish, because the library goes quiet with nothing to say. The empty value rides along for the rest of the session |

The second case is the one that needs the guarantee: with nothing left to publish, a lost
retraction could never be corrected. Carrying the empty value costs a few bytes per retired
key. It disappears entirely when the game restarts.

Call `unregister` in `on_disabled` and `on_unload`. A registered consumer that is never
unregistered keeps its capability entry and last payload published.

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
Manifold.usage() -> { count, bytes, largest, keys = { [id] = bytes }, limit }
```
`count` is the number of registered consumers. `bytes` is the sum of every published
key's encoded length, informational only. `largest` is the size of the single largest
published value; compare it against `limit` (250) for real headroom, because the
backend's cap is per value, not aggregate. `keys[id]` is the size a consumer's value
would have been, so a shed consumer reports the size that got it shed and can exceed
`limit`.

## Example

A complete minimal consumer. The mod shares each player's three curio resistances so the
party can see coverage gaps. It demonstrates the four patterns that a consumer must get
right: registration with a versioned payload, marking dirty on change, reading every
member through one uniform loop, and teardown.

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

-- The consumer's own current state, recomputed locally. This is what the builder
-- publishes, and it is always fresher than what get() reports for the local player.
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
    mod.manifold_unsub = Manifold.on_update(ID, function()
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

        -- has_mod now answers for the local player too, so one branch covers everyone.
        if Manifold.has_mod(member, ID) then
            local name, resists

            if Manifold.is_myself(member) then
                -- Prefer live local state. get() would work here, but it lags by up
                -- to the two-second publish interval.
                name, resists = "You", my_resists
            else
                name = member.name and member:name() or "?"
                resists = decode(Manifold.get(member, ID))
            end

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
- `has_mod` gates the read for every member including the local player, so one branch
  covers the whole party and a member who does not run Curio Coverage produces no row.
- The local row is still drawn from `my_resists`. `get` would answer, but it reports the
  last published value, which trails live state by up to the publish interval.
- `on_update` is passed `ID`, so a fault in the callback is reported against Curio
  Coverage by name instead of being silently skipped.
- `on_disabled` and `on_unload` both unregister the consumer and drop the `on_update`
  callback, so a hot reload does not leak a registration or a closure.

## Payload versioning

Vox Manifold versions the envelope, not the consumer payload. The payload table under a
consumer's id is opaque to the library. A consumer that changes its payload shape
between releases is responsible for its own compatibility: include a version field in
the payload, and have the reader tolerate older and newer shapes. A consumer that omits
this will break its own cross-version reads when users run mixed builds.

## Envelope format

Each consumer publishes its own presence key, `vm_<mod id>`, with the mod id escaped so
it is a valid key: every `_` becomes `_u` first, then every `.` becomes `__` (order
matters, or the two escapes collide). `wobin.havoc` becomes `vm_wobin__havoc`;
`lucleto.overflow_meter` becomes `vm_lucleto__overflow_umeter`.

The value at that key is a single JSON object:

```json
{ "v": 2, "m": "<mod version>", "d": { } }
```

- `v` is the envelope version.
- `m` is the consumer's version string, capped at 32 source bytes.
- `d` holds the consumer's payload. It is omitted entirely when the builder returns
  nothing, which is how a reader distinguishes "no payload" from "empty payload".

The keys `v`, `m`, and `d` are permanent. A future envelope version may add sibling keys
but must not repurpose these three. A reader ignores an unrecognised envelope version's
additions and reads `d` on a best-effort basis, so a newer publisher degrades on an
older reader rather than failing.

Vox Manifold 1.x published every consumer multiplexed into one shared key, `dtmods`,
holding `{ "v": 1, "c": { "author.name": "version" }, "d": { "author.name": { } } }`.
2.x still reads that key, so a party member who has not updated stays visible, but it
never writes it: writing it would reinstate the per-value overflow that the key-per-
consumer design exists to fix.

## Efficiency and limits

Every consumer gets its own presence key, `vm_<mod id>`, and its own independent
256-byte budget that does not shrink as other mods are added. They share one hook on
the presence map and one coalesced, rate-limited publish cycle, so adding a consumer
introduces no extra network write: all keys go out in a single merged update.

The Darktide backend caps a single presence value at 256 bytes and drops the entire
presence stream when one exceeds it, which takes party, friends and social down with
it. Vox Manifold therefore treats 250 bytes as a hard ceiling per consumer. A payload
that would exceed it is dropped and the offending mod is named in the log; the mod
stays advertised so peers still see it is running, and no other consumer is affected.
A warning fires at 200 bytes so you get notice before that happens.

Your usable payload budget is `250 - 19 - #version` bytes: 250 minus 19 bytes of fixed
envelope framing minus the length of your own version string, because the version rides
on the wire inside every value. For a typical 5-character version like `2.1.0`, that
works out to 226 bytes; a longer version string eats directly into your budget (a
32-character version leaves only 199 bytes). Keep payloads small: publish a reference
(an id or hash the reader resolves locally) rather than a large blob. The presence value
is shared party traffic on an undocumented backend surface; a lean payload is a courtesy
to that surface and to the backend's unknown limit on key count.

There is no consumer-count limit, but each registered consumer takes its own key, and
the backend's limit on the number of key-values a client can publish is unknown. A
warning fires once past 8 registered consumers so this stays visible rather than
silent.

A payload that cannot be encoded at all (a function, a cycle) is dropped and logged as
an error, so one broken payload cannot suppress the others. The consumer remains
advertised in the capability record.

The one hard bound on the read path: an inbound peer value larger than 16384 bytes is
rejected before parsing. This bounds decode cost against a hostile or corrupt peer and
is unrelated to the per-value budget; a legitimately sized value well under it still
decodes.

## Diagnostics and troubleshooting

Registration errors are documented with [`register`](#api), because you meet them while
writing the call. Everything below happens later, asynchronously, so it is logged rather
than returned. All log lines are prefixed `[Vox Manifold]`.

### Publish-time diagnostics

These are logged, not returned, because they happen during a publish rather than a call
you made. Each is reported **once** per consumer and clears itself if the condition goes
away, so a payload that grows past a threshold and later shrinks will warn again if it
regresses.

**Warning: `<Mod> payload is <n> bytes, past the 200-byte comfort line. The hard limit is 250 bytes, after which the payload is dropped.`**

Advance notice. You are still publishing normally. Trim the payload before it reaches the
ceiling.

**Error: `<Mod> payload is <n> bytes, over the 250-byte backend limit for a single presence value. The payload was dropped; the mod is still advertised. Publish less state.`**

Your payload was shed. Peers can still see that you run the mod, via `has_mod`, but `get`
returns `false` for you because there is no data. Nobody else is affected.

Long keys and human-readable display strings are what usually does it. The two payloads
below carry the same information; the sizes are measured, not estimates.

```lua
-- 262 bytes, SHED. Only the 19-byte capability record reaches the wire.
local function build_payload()
    return {
        rank = 40, charges_remaining = 3, mission_name = "Chasm Logistratum",
        circumstances = { "Hunting Grounds", "Snipers Everywhere", "Power Supply Interruption" },
        player_name = "Wobin", last_updated = 1785000000,
        difficulty = "Havoc 40", auric = true,
    }
end

-- 78 bytes, published. Short keys, backend ids, nothing the reader can derive itself.
local function build_payload()
    return { r = 40, c = 3, m = "km_enforcer", f = { "hg", "sn", "psi" } }
end
```

The savings come from three habits: single-letter keys, backend ids instead of display
names, and omitting anything the reading side already knows or can look up. The player's
name and the timestamp in the first version are both things the reader already has.

**Error: `<Mod> payload is not encodable and was omitted. The mod is still advertised.`**

The builder returned a table that cannot become JSON. Causes: a cycle, a function or
userdata value, `nan` or `inf`, or a key that is neither a string nor a number.

```lua
return { unit = my_unit }             -- userdata
return { on_done = callback }         -- function
return { ratio = hits / shots }       -- nan when shots is 0
local t = {}; t.self = t; return t    -- cycle
```

**Warning: `<n> consumers now hold a presence key each, more than the 13 the game itself publishes. Nothing is known to be wrong: the backend's limit on key count is undocumented and untested past this point. Noted here so it is on record if presence misbehaves.`**

Fires once, past 13 consumers. Nothing is broken and there is nothing to do.

The threshold is 13 because that is the only number with evidence behind it. The engine
publishes exactly 13 presence keys every session, and Vox Manifold 1.x added a fourteenth
successfully, so 14 keys is known to work. Beyond that nobody has measured anything: the
backend's limit on key count, if it has one, is undocumented, and no client-side code
enforces one. Thirteen consumers is the point where this library is putting more keys on
your presence entry than the game does, which is the last footprint known to be accepted.

It is a warning rather than a cap deliberately. Enforcement is justified where breach is
known to be catastrophic, which is true of the per-value size limit and is not known to be
true of the count; a hard cap on a guess would break working setups to prevent something
hypothetical. The consumer count also appears in every publish log line, so this exists to
leave a prominent marker for whoever is diagnosing a broken presence stream later.

**Error: `refused to publish: a presence value exceeded the 250-byte limit after shedding. Nothing was sent.`**

A safety net that should be unreachable, since shedding already guarantees the bound.
Reported once. If you ever see it, please open an issue: it means a value got past two
independent size guards.

### Consumer-callback diagnostics

**Warning: `on_update listener from <who> errored and was skipped: <error>. This is a fault in that consumer, not in Vox Manifold. Further errors from this listener are suppressed until it succeeds again.`**

Your `on_update` callback threw. Listeners run inside a `pcall` so that one broken
consumer cannot stop the others being notified, which means the error would otherwise
vanish with no trace: the symptom is a mod that quietly stops updating forever.

Reported once per listener per failure episode, not once per event, because listeners
fire on every party change. A listener that recovers and later fails again reports again.

`<who>` is your mod name and id when you passed one to `on_update`, or when the library
matched the callback's file to a registered consumer. When it could not match, it names
the file and says so, rather than blaming a consumer it is not sure about.

Note this is logged under Vox Manifold's prefix but is not a fault in the library. The
error text carries the file and line inside your callback where the throw happened.

### Engine-contract errors

Reported **once per session** each. These mean a game patch moved something the library
depends on. They are not caused by your mod and you cannot fix them from a consumer.

| Message | Effect |
| --- | --- |
| `PresenceEntryMyself.create_key_values is missing. The game has changed; no mod state can be published.` | Nothing publishes at all |
| `Managers.presence._update_my_presence is missing. The game has changed; mod state cannot be published.` | Publishes are not pushed |
| `presence entry has no _key_value_string. The game has changed; no party member state can be read.` | Peers cannot be read |
| `presence push failed: <error>` | One push threw |
| `create_key_values failed upstream: <error>. Publishing mod keys only; engine presence fields are left as they are.` | Another mod's hook on the same engine function threw. Vox Manifold keeps working; the other mod is broken |

### What silence means

The transport fails silently. If the backend rejects a value, publishing continues to no
effect and peers simply appear not to run your mod, with no transport error anywhere.
That is why the log lines above exist, and why `usage()` is worth checking when something
does not appear:

```lua
local u = Manifold.usage()
mod:info(("%d consumers, largest value %d of %d bytes"):format(u.count, u.largest, u.limit))
for id, bytes in pairs(u.keys) do
    mod:info(("  %s wanted %d bytes"):format(id, bytes))
end
```

`largest` against `limit` is your real headroom, because the cap is per value. A figure in
`keys` that exceeds `limit` is a consumer whose payload was shed.

Enable the `vm_debug` setting for per-publish and per-peer-decode logging.

## Changes in 2.1

No consumer needs a code change. Both changes are additive, and the second only makes an
existing call report better.

**`get` and `has_mod` now answer for the local player.** They previously returned `nil`
for yourself, so a reader had to special-case `is_myself` before every read. They now
report what you last published, decoded from the same bytes your peers receive, and
`has_mod` falls back to the local registry before the first publish. A reader that already
special-cases the local player keeps working unchanged, and is still the better choice
when it needs live state rather than published state.

**`on_update` takes an optional id**, used only to attribute an error in your callback.
Existing one-argument calls are unaffected: the library matches the callback's file against
registered consumers and usually names you correctly anyway. Pass the id if you are a
read-only consumer, since one that never calls `register` cannot be matched.

Errors thrown inside an `on_update` callback were previously discarded in silence. They are
now logged once per failure, which may surface a pre-existing fault in a consumer that
looked like it had simply stopped updating.

## Migrating from 1.x

Consumers almost certainly need no code changes. `register`, `unregister`, `mark_dirty`,
`get`, `has_mod`, `members`, `is_myself` and `on_update` all keep their signatures, and
`get` keeps its three return states: a table when the peer has data, `false` when they
run the mod but have nothing to say, and `nil` when they do not run it at all.

"Almost certainly" rather than "certainly", because one contract did narrow. `register`
gained three rejections, and a call that previously succeeded can now fail:

- **A non-function `builder`.** Calling `Manifold.register(id, mod)` with the builder
  omitted used to succeed. It then advertised your mod to the entire party while being
  structurally incapable of ever publishing a payload, and said nothing about it. It now
  fails loudly at registration instead.
- **A non-table `owner`.** The owner is what the id-squatting check compares, so passing
  `nil` made every caller present the same identity and defeated it.
- **A `version` that is not a string or is longer than 32 characters,** because the
  version rides on the wire inside every published value and an unbounded one could
  breach the backend's per-value cap on its own.

If you pass your mod object and a real builder function, which is what the examples above
do and almost certainly what you already do, none of these will ever fire. They are called
out here rather than left for you to discover from a `register` that quietly returns nil.

Two other things changed, neither of which requires action:

- `usage()` returns `{ count, bytes, largest, keys = { [id] = bytes }, limit }`. It
  previously returned `{ count, bytes }` measuring one shared envelope. `largest` is the
  number that matters: the backend's cap is per value, so `largest` against `limit` is
  your real headroom. `bytes` is the sum across all keys and is informational only.
  `keys[id]` is the size a consumer's value WOULD have been, so a shed consumer reports
  the size that got it shed and can exceed `limit`.

Your payload budget is now 226 bytes and it is yours alone. To see what the old shared
budget actually cost, here are the measured sizes from the report that prompted this
release, two consumers under 1.x:

| Contents of the single shared value | Bytes |
| --- | --- |
| Capability records only, no payloads | 75 |
| Plus Havoc Auspex's 137-byte payload | 226 |
| Plus Overflow Meter's 59-byte payload | 311 |

The backend rejected the third one and dropped the presence stream. Under 2.x those
same two consumers occupy 161 and 83 bytes in their own keys, each independently inside
the limit, and neither can affect the other.

Vox Manifold 2.x reads 1.x peers, so a party member who has not updated stays visible
to you. It never publishes the 1.x format, because that is what caused the overflow.

**That compatibility is one-way.** A member still on 1.x reads only the old shared key,
which 2.x never writes, so you are invisible to them. In a mixed party the two readouts
disagree: a 2.x member sees everyone, a 1.x member sees only other 1.x members.

Nothing crashes and nothing is corrupted in either direction. A 1.x client reading a
2.x member simply finds no value and concludes they do not run the consumer, which is
the same path it takes for anyone who genuinely does not.

The fix is for them to update, which they want regardless: 1.x drops their entire presence
stream as soon as they run two consumers, and once that happens nobody can read them at
all, on any version.

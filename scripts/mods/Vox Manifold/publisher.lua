local math_huge = math.huge

return function(opts)
    local min_interval = opts.min_interval

    local dirty = false
    local elapsed = math_huge
    local last_sent = nil

    local pub = {}

    function pub.mark_dirty()
        dirty = true
    end

    function pub.force()
        last_sent = nil
    end

    function pub.update(dt, encode_fn)
        elapsed = elapsed + dt

        if not dirty then
            return nil
        end
        if elapsed < min_interval then
            return nil
        end

        dirty = false

        local encoded = encode_fn()
        if not encoded then
            elapsed = 0
            return nil
        end

        if encoded == last_sent then
            return nil
        end

        last_sent = encoded
        elapsed = 0

        return encoded
    end

    return pub
end

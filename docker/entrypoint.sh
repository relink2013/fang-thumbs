#!/bin/sh
# Runs fang-thumbs as PUID:PGID (default 99:100). With the DAC_READ_SEARCH capability added to the container,
# it keeps just that one, so files with restrictive modes still get previews; without it, it reads what that
# user can read.
mkdir -p "$FANG_THUMBS_CACHE" && chown "$PUID:$PGID" "$FANG_THUMBS_CACHE"
caps="--inh-caps=-all,+dac_read_search --ambient-caps=-all,+dac_read_search --bounding-set=-all,+dac_read_search"
if setpriv --reuid="$PUID" --regid="$PGID" --clear-groups $caps true 2>/dev/null; then
    exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups $caps /usr/local/bin/fang-thumbs
fi
exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups --inh-caps=-all --bounding-set=-all /usr/local/bin/fang-thumbs

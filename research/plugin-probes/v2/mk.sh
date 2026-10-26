#!/bin/bash
# mk.sh name  < body : write name.roc with the pinned app header, then check it.
URL=$(cat /home/george/dev/Karakatiza666/talon/cloudflare-workers/research/plugin-probes/v2/URL)
f="$1.roc"
{ echo "app [event!] { pf: platform \"$URL\" }"; echo; cat; } > "$f"
/home/george/dev/Karakatiza666/talon/cloudflare-workers/research/plugin-probes/v2/chk.sh "$f"

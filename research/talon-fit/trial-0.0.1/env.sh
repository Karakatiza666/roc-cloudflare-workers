# Source this file: isolated Talon state for the trial (no change to ~/.cache, ~/.config, ~/.local).
T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XDG_CACHE_HOME="$T/.state/cache" XDG_CONFIG_HOME="$T/.state/config" XDG_DATA_HOME="$T/.state/data"
export PATH="$T/.state/bin:$PATH"

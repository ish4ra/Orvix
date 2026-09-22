# stream-server notice

Orvix Windows builds include an MIT-licensed stream-server executable for local
BitTorrent/P2P streaming.

Upstream: https://github.com/stremio-native/stream-server
Pinned upstream commit: f585ab6eda9b1411034548c131bb0dc30c6f5f9e
Upstream lineage: v0.1.8
License: MIT

## Orvix modifications

The Orvix Windows build uses a source-level modification of the pinned upstream
stream-server. The modification keeps the existing upstream routes and adds an
exact-selected-file embedded subtitle path for torrent/season packs:

- embedded subtitle discovery can target the exact torrent video file index
  currently selected by Orvix instead of the upstream largest-video heuristic;
- embedded extraction carries both the selected video file index and subtitle
  track ID;
- /orvix/capabilities advertises whether exact-file embedded subtitle support is
  available;
- requests that do not supply an exact video file index retain upstream
  compatibility behavior.

The reproducible build patch is stored in:
tools/patch_orvix_stream_server.py

Design notes are stored in:
docs/ORVIX_STREAM_SERVER_MOD.md

Inside Orvix packages the binary is renamed to:
orvix-stream-server.exe

# Third-party software in this package

## UE4SS (RE-UE4SS)
`dwmapi.dll`, `ue4ss/UE4SS.dll`, `ue4ss/Mods/shared/UEHelpers`, `ue4ss/UE4SS-settings.ini` and
`ue4ss/UE4SS_Signatures/*` (the Far Far West game config from UE4SS's zCustomGameConfigs).
Build: experimental-latest `UE4SS_v3.0.1-1164-g5e627997` from https://github.com/UE4SS-RE/RE-UE4SS.
License: MIT, Copyright (c) 2022 Narknon (full text in `ue4ss/LICENSE`).

## repak
Compiled into `tools/rsf-extract.exe`. https://github.com/trumank/repak (commit 355b5f62).
License: MIT OR Apache-2.0, Copyright spuds and trumank.

Also compiled in (MIT/Apache-2.0 or similarly permissive Rust crates): flate2, zlib-rs, zstd (zstd is
BSD-licensed, Copyright Meta Platforms), lz4_flex, serde, serde_json, byteorder, sha1, strum, hex, thiserror.

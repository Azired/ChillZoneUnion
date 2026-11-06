# Legacy transfer protocol fixture

`Transfers-0.9.2.lua` is the unchanged production transfer module from
ChillZoneUnion 0.9.2-beta, commit `25b39d29b422cb538cad7bfd35b6cc9a768648a3`.

- Git blob: `fe424f64a06ab141b452df14d822d3dfe1d6b5e8`
- SHA256: `411544C5532868A4AAD2282516CF3AC0A1EF005ADF41CD1AB5CB3B8FD30B883D`

The audit harness loads this module for legacy clients while retaining the
current production modules for all other behavior. Their advertised version is
explicitly set to `0.9.2-beta`. These clients therefore retain the real legacy
behavior of rejecting donor recovery requests while participating in native
GUILD/WHISPER transport, election and permission checks.

The fixture is used locally; the tests require no archived output folder or
network access. It is excluded from the player addon package with the Tests
directory.

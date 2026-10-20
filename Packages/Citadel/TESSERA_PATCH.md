# Tessera Citadel patch

This directory vendors Citadel 0.12.1 at upstream revision
`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`.

Tessera adds two future-based entry points used by `SSHConnectionChain`:

- `SSHClient.startConnection(on:settings:)` installs the SSH handlers
  synchronously on the channel's event loop, then returns the authentication
  future.
- `SSHClient.createDirectTCPIPChannelFuture(using:initialize:)` exposes jump
  channel creation without cancellation-blind `EventLoopFuture.get()`.

These adapters let Tessera retain and close direct and tunneled channels when a
host-key attempt is deliberately aborted for human approval, including on iOS
17 where custom task executors are unavailable.

Remote Files transfers keep several SFTP requests in flight instead of waiting
a round trip for each:

- `SFTPFile.writeFuture(_:at:)` sends a buffer as consecutive write requests
  of at most `SFTPFile.maximumWriteRequestLength` (32,000) bytes and returns
  one future for all of their acknowledgements.
- `SFTPFile.readFuture(from:length:)` sends one read request and returns its
  reply; end of file yields an empty buffer.
- Both use `SFTPClient.sendRequestFuture(_:)`, which `sendRequest(_:)` now
  awaits. `SFTPClient.setupChannelHanders(channel:logger:)` is internal rather
  than fileprivate so `SFTPPipelinedRequestTests` can drive an in-memory channel.

The upstream example and test targets are omitted from the local package
manifest; library sources are otherwise unchanged.

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
manifest.

## Compiler warning fixes

Pipeline installation and SSH handler lookup use NIO's synchronous operations
on the channel's event loop; `NIOLoopBound` carries handlers between callbacks.
`SSHAlgorithms` stores only immutable transport metatypes, while its generic
modification enum is conditionally `Sendable`. Custom host-key and server
authentication delegates must be `Sendable`; the server and shell context
values have checked conformances. Shell tasks capture their delegate and stream
values instead of the channel handler. Remote-forward generic types are explicit
at the forwarding helper's existing `ByteBuffer` call site.

Exec termination failures after channel inactivity now close the local pipe and
release the command context. Environment requests that want a reply get one,
success or failure (RFC 4254 §6.4), and a refused variable leaves the channel
open. A failed stdin EOF is still ignored, so the command keeps its output.
Successful task and close ordering is unchanged.

The direct-TCPIP setup callback explicitly retains its existing strong channel
capture, while the installed proxy retains its weak capture. Pipe bootstrap uses
the renamed descriptor-ownership API, and bcrypt PBKDF uses a distinct macro name
for its unchanged eight-word count, separate from bcrypt's six-word count. Off
Apple platforms its failure path fills the key with `getentropy` 256 bytes at a
time and checks each call (zeroing what it cannot fill), where one unchecked call
left keys over 256 bytes untouched.

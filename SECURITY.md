# Security policy

Please do not open a public issue for a suspected vulnerability. Report it to
the repository owner through GitHub's private vulnerability reporting once it
is enabled.

Never attach personal media, database files, pairing QR codes, tokens, signing
keys or server logs containing private paths to an issue.

The direct-download builds are early access. Device pairing, signed requests,
root-path authorization, traversal tests, rate limiting, revocation and audit
controls are implemented. Use a trusted home LAN or a private Tailscale network;
do not expose the server with public port forwarding. Consult the threat model
and implementation status for remaining physical-device and independent-review work.

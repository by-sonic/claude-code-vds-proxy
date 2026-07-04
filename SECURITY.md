# Security policy

## Reporting a vulnerability

Please do not publish working exploit details in a public issue. Open a GitHub
Security Advisory for this repository, or contact the maintainer through the
private contact channel listed on the GitHub profile.

Include the affected file/version, impact, reproduction steps and a suggested
fix when possible. Do not include real SSH keys, tokens, account cookies, VDS
addresses or private logs.

## Trust model

The installer runs privileged operations on both macOS and the VDS. Review the
scripts before running them. Pin or inspect the commit you install in managed
environments.

The project does not protect software that ignores proxy variables, uses
literal destination IPs, performs custom DNS/DoH resolution, or opens traffic
through MCP servers and shell commands. See the limitations in the README.

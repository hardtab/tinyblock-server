# Contributing

Thank you for your interest in Tiny Block Server!

## Scope

This repository contains the dedicated server source for Tiny Block. Contributions that:

- Fix simulation bugs or desync issues.
- Improve server reliability, persistence, or reconnection.
- Add configuration options.
- Improve documentation.
- Add tests.

are especially welcome.

Contributions that:

- Add client-side features, rendering, or UI.
- Introduce new dependencies on mobile, store, or advertising SDKs.
- Require new network protocol versions.
- Change the world save format in a breaking way.

will likely be rejected or asked to go through a separate RFC process.

## Before you start

- Open an issue first for significant changes to discuss approach.
- Keep PRs focused on one concern.
- Respect the existing architecture: do not rewrite the simulation, multiplayer, or persistence layer.

## Development setup

1. Fork this repository.
2. Clone your fork.
3. Install Godot 4.7+ with Linux export templates.
4. Run existing tests:

```bash
godot --headless --path . tests/server_test_runner.tscn
```

## Code style

- GDScript with tabs, matching Godot's formatter.
- snake_case for variables and functions.
- UPPER_SNAKE_CASE for constants.
- Prefer explicit typing (`var value: int`) over inferred.
- One class per file, filename matching class/autoload name.
- Keep server-specific code separate from the reused simulation.

## Testing

- Add tests for new functionality in `tests/`.
- Run the full test suite before submitting a PR.
- Test at least two world modes if your change touches simulation or persistence.

## License

By contributing, you agree that your contributions will be licensed under AGPL-3.0-or-later.

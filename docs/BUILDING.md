# Building HyperBEAM Locally

The HyperBEAM repository occasionally collects release artefacts (for example a `lib/` directory populated with OTP applications). These artefacts are safe to keep for deployment, but they confuse `rebar3` during dependency discovery and can cause the BEAM VM to allocate gigabytes of memory before the kernel terminates the build.

Before running `rebar3` locally, reset the workspace:

```bash
./ops/reset_workspace.sh
```

The script removes the generated `lib/` tree and `_build/` so that `rebar3` only works with the source code in the repository and fetches runtime dependencies from Hex/git. After resetting you can run the normal build commands, e.g.

```bash
REBAR_LOG_LEVEL=info rebar3 compile
rebar3 eunit
```

If you need the release artefacts again, rebuild them via the usual release workflows instead of committing them back into the repository.

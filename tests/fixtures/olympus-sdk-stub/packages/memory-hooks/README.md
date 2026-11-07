# olympus-sdk stub (CI only)

Stand-in for the private `nwlnexus/olympus-sdk` flake input so the public CI
runner can evaluate this flake without credentials. The evaluation tests only
read its `rev` and interpolate paths under it (config/claude/*.json, which the
stub lacks, so autoMode and telemetry stay unset); they never build it. See `.github/workflows/validate.yml`.

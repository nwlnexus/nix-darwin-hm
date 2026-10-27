# olympus-sdk stub (CI only)

Stand-in for the private `nwlnexus/olympus-sdk` flake input so the public CI
runner can evaluate this flake without credentials. The evaluation tests only
interpolate the path `${inputs.olympus-sdk}/packages/memory-hooks`; they never
build it or read files from it. See `.github/workflows/validate.yml`.

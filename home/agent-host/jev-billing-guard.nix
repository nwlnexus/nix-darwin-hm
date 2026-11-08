# jev-router billing guard (olympus-sdk#647): a pure function from what the module would deploy to the list of
# reasons it must not, one message per broken rule. home/agent-host/jev-router.nix turns each message into a failed
# assertion; tests/jev-router.nix calls this function directly, so each fixture is checked against its own message
# (a home configuration with a failed assertion throws as a whole, so its assertions cannot be read back).
#
# Rule: Claude Code keeps the claude.ai subscription login only while no API credential is set anywhere in the chain
# (ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, apiKeyHelper), every router target forwards the client's own login, and
# the OAuth beta header is never dropped.
{ lib }:
{
  # attrset: where -> list of setting names (managed Claude settings, telemetry env, home.sessionVariables)
  managed,
  # list of "NAME=value" strings: the router unit's Environment
  unitEnv,
  # attrset: env name -> 1Password reference (d.agentHost.jevRouter.secretEnv)
  secretEnv,
  # attrset: surface -> target name -> target (the router config's `surfaces`)
  surfaces,
}:
let
  forbidden = [
    "ANTHROPIC_API_KEY"
    "ANTHROPIC_AUTH_TOKEN"
    "apiKeyHelper"
  ];
  names = lib.concatStringsSep ", " forbidden;
  managedHits = lib.filterAttrs (_: ns: lib.any (n: lib.elem n forbidden) ns) managed;
  unitHits = lib.filter (e: lib.any (n: lib.hasPrefix "${n}=" e) forbidden) unitEnv;
  secretHits = lib.filter (n: lib.elem n forbidden) (lib.attrNames secretEnv);
  targets = lib.concatLists (
    lib.mapAttrsToList (
      surface: ts: lib.mapAttrsToList (name: t: t // { where = "surfaces.${surface}.${name}"; }) ts
    ) surfaces
  );
  badAuth = lib.filter (t: (t.keyEnv or null) != null || (t.clientAuth or false) != true) targets;
  badBetas = lib.filter (
    t: lib.any (b: lib.hasInfix "oauth" (lib.toLower b)) (t.omitBetas or [ ])
  ) targets;
  where = ts: lib.concatMapStringsSep ", " (t: t.where) ts;
in
lib.optional (managedHits != { })
  "jev-router billing guard: ${names} must not be set in managed Claude settings (found in ${lib.concatStringsSep ", " (lib.attrNames managedHits)})."
++ lib.optional (
  unitHits != [ ]
) "jev-router billing guard: the router unit's Environment must not set ${names}."
++ lib.optional (
  secretHits != [ ]
) "jev-router billing guard: d.agentHost.jevRouter.secretEnv must not carry ${names}."
++
  lib.optional (badAuth != [ ])
    "jev-router billing guard: every target must use the client's own login (clientAuth = true, no keyEnv): ${where badAuth}."
++ lib.optional (
  badBetas != [ ]
) "jev-router billing guard: omitBetas must never drop the OAuth beta: ${where badBetas}."

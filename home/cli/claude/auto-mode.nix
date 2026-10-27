# Build the settings.json `autoMode` value from an auto-mode source file (olympus-sdk#576, HW17 layer 2).
#
#   import ./auto-mode.nix { inherit lib; } <file> <host or null>
#
# The file is JSON: { "allow": [..], "environment": [..], "hostContainment": { "<host>": "..", "default": ".." } }.
# The result is { allow; environment; }, where environment gets one more entry, "**Host containment**: " followed
# by hostContainment.<host> (or hostContainment.default when the host is null or not listed; no entry when
# neither exists). hostContainment itself is not passed on. Pure, so tests can feed it a fixture.
{ lib }:
file: host:
let
  src = lib.importJSON file;
  containment = src.hostContainment or { };
  line =
    if host != null && containment ? ${host} then containment.${host} else containment.default or null;
in
{
  allow = src.allow or [ ];
  environment =
    (src.environment or [ ]) ++ lib.optional (line != null) "**Host containment**: ${line}";
}

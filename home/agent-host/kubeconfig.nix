# Credential-free kubectl over the tailnet (olympus-sdk#935). The Tailscale operator's API-server proxy
# authenticates the host by its tailnet identity and impersonates the group the tailnet policy grants its tag
# (tag:agent-host -> olympus:agents-view, read-only). The kubeconfig holds no credential: the token is the
# placeholder `tailscale configure kubeconfig` writes, and the proxy ignores it.
#
# The activation writes cluster/user/context entries named after `context` into ~/.kube/config, and only while
# that file holds no client key (the admin kubeconfig): it never merges next to, or overwrites, an admin
# credential. Remove the admin kubeconfig by hand first (runbook on olympus-sdk#935); the next switch then
# writes this one. The tailnet's MagicDNS suffix is read from `tailscale status` at activation, so no tailnet
# name is committed here. Fail-soft: no tailscale, or tailscale down, leaves the file as it is.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.d.agentHost.kubeconfig;
  kubeconfig = "${config.home.homeDirectory}/.kube/config";
in
{
  options.d.agentHost.kubeconfig = {
    enable = lib.mkEnableOption "the read-only kubeconfig through the Tailscale operator's API-server proxy";
    proxyHost = lib.mkOption {
      type = lib.types.str;
      default = "compute-hub-operator";
      description = "Tailnet hostname (without the MagicDNS suffix) of the operator's API-server proxy.";
    };
    context = lib.mkOption {
      type = lib.types.str;
      default = "compute-hub";
      description = "Context, cluster and user name to write (the name the repositories use).";
    };
  };

  config = lib.mkIf (config.d.agentHost.enable && cfg.enable) {
    home.activation.agentHostKubeconfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      KCFG=${lib.escapeShellArg kubeconfig}
      # The activation PATH may not hold the system tailscale (apt on Linux, not Nix).
      TS="$(command -v tailscale || true)"
      for c in /usr/bin/tailscale /usr/local/bin/tailscale; do
        [ -z "$TS" ] && [ -x "$c" ] && TS="$c"
      done
      if [ -f "$KCFG" ] && ${pkgs.gnugrep}/bin/grep -q 'client-key-data' "$KCFG"; then
        echo "agentHostKubeconfig: $KCFG holds a client key (admin kubeconfig); not writing the tailnet context" >&2
      elif [ -z "$TS" ]; then
        echo "agentHostKubeconfig: tailscale not found; skipped" >&2
      else
        SUFFIX="$("$TS" status --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.MagicDNSSuffix // empty')"
        if [ -z "$SUFFIX" ]; then
          echo "agentHostKubeconfig: tailscale status gave no MagicDNS suffix; skipped" >&2
        else
          K="${pkgs.kubectl}/bin/kubectl --kubeconfig $KCFG"
          run install -d -m 0700 "$(dirname "$KCFG")"
          run $K config set-cluster ${lib.escapeShellArg cfg.context} --server="https://${cfg.proxyHost}.$SUFFIX" >/dev/null
          run $K config set-credentials ${lib.escapeShellArg cfg.context} --token=unused >/dev/null
          run $K config set-context ${lib.escapeShellArg cfg.context} --cluster=${lib.escapeShellArg cfg.context} --user=${lib.escapeShellArg cfg.context} >/dev/null
          run $K config use-context ${lib.escapeShellArg cfg.context} >/dev/null
          run chmod 0600 "$KCFG"
        fi
      fi
    '';
  };
}

# home/apps/claude-mem.nix
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.d.apps.claudeMem;
  homeDir = config.home.homeDirectory;
in {
  options.d.apps.claudeMem = {
    enable = mkEnableOption "claude-mem server-beta client configuration";

    serverUrl = mkOption {
      type = types.str;
      default = "http://claude-mem.raptor-mimosa.ts.net:37878";
      description = "claude-mem server-beta URL via Tailscale MagicDNS";
    };

    projectId = mkOption {
      type = types.str;
      default = "olympus";
    };

    apiKeyFile = mkOption {
      type = types.str;
      default = "${homeDir}/.config/claude-mem/api-key";
      description = "Path written by op-secrets; read by activation script";
    };
  };

  config = mkIf cfg.enable {
    # Write the server-beta API key from 1Password to a 0600 file on disk.
    # The activation script below reads it to avoid interactive prompts.
    op-secrets.secrets.claude-mem-api-key = {
      account = "my.1password.com";
      source = "op://Dev/claude-mem-server/api-key";
      dest = cfg.apiKeyFile;
      mode = "0600";
    };

    # Smart-merge: patch only the 4 server-beta keys into ~/.claude-mem/settings.json.
    # Uses home.activation (never home.file) so existing settings are preserved.
    # Skips gracefully if the API key file hasn't been written yet by op-secrets
    # (will apply on next `darwin-rebuild switch`).
    home.activation.claudeMemServerBeta = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      SETTINGS="${homeDir}/.claude-mem/settings.json"
      API_KEY_FILE="${cfg.apiKeyFile}"

      if [ ! -f "$API_KEY_FILE" ]; then
        echo "claude-mem: API key not yet present at $API_KEY_FILE — skipping patch (run darwin-rebuild switch again after op-secrets writes the key)"
        exit 0
      fi

      API_KEY=$(cat "$API_KEY_FILE")

      if [ -z "$API_KEY" ]; then
        echo "claude-mem: API key file is empty — skipping patch"
        exit 0
      fi

      if [ ! -f "$SETTINGS" ]; then
        mkdir -p "$(dirname "$SETTINGS")"
        printf '{}' > "$SETTINGS"
      fi

      PATCHED=$(${pkgs.jq}/bin/jq \
        --arg url "${cfg.serverUrl}" \
        --arg key "$API_KEY" \
        --arg project "${cfg.projectId}" \
        '. + {
          "CLAUDE_MEM_RUNTIME": "server-beta",
          "CLAUDE_MEM_SERVER_BETA_URL": $url,
          "CLAUDE_MEM_SERVER_BETA_API_KEY": $key,
          "CLAUDE_MEM_SERVER_BETA_PROJECT_ID": $project
        }' "$SETTINGS")

      CURRENT=$(cat "$SETTINGS")
      if [ "$PATCHED" != "$CURRENT" ]; then
        printf '%s' "$PATCHED" > "$SETTINGS"
        echo "claude-mem: patched settings.json with server-beta configuration"
      fi
    '';
  };
}

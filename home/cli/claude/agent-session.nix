# agent-session launcher (~/.local/bin/agent-session): an interactive Claude Code session in tmux with Remote
# Control attached, named <account>-<repo>-<issue>. Spec H17 substrate (b); issue olympus-sdk#561.
# Agent hosts run it with CLAUDE_CONFIG_DIR=~/.claude-<account> (home/agent-host); the Macs have one ~/.claude.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agentHost = config.d.agentHost or { enable = false; };
  agentSession = pkgs.writeShellApplication {
    name = "agent-session";
    # tmux comes from the user's PATH (home/cli/tmux.nix), so the launcher and the interactive shell talk to the
    # same server.
    text = ''
      AGENT_SESSION_PER_ACCOUNT=${if agentHost.enable then "1" else "0"}
    ''
    + builtins.readFile ./agent-session.sh;
  };
in
{
  home.file.".local/bin/agent-session".source = "${agentSession}/bin/agent-session";
}

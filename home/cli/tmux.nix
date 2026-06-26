{ ... }:
{
  programs.tmux = {
    enable = true;

    # tmux-256color advertises full capabilities (italics, true color) to apps.
    terminal = "tmux-256color";

    # Low escape time so extended keys / Vim mode changes feel instant.
    escapeTime = 10;

    historyLimit = 50000;
    baseIndex = 1;
    keyMode = "vi";
    mouse = true;

    extraConfig = ''
      # --- Claude Code / modern terminal integration ---
      # Allow Claude to forward notifications and progress bars
      set -g allow-passthrough on
      # Properly pass extended keys (fixes Shift+Enter for newlines)
      set -s extended-keys on
      set -as terminal-features 'xterm*:extkeys'
      # Enable focus events (required for Neovim/Vim auto-read)
      set -g focus-events on

      # True color passthrough for terminals that support it (incl. iTerm2)
      set -as terminal-features ',xterm*:RGB'
      set -ag terminal-overrides ',xterm*:Tc'
    '';
  };
}

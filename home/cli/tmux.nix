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
      set -as terminal-features 'tmux-256color:extkeys'
      # Re-emit the CSI u sequence for Shift+Enter so Claude Code inserts a
      # newline instead of submitting. Requires the iTerm2 profile to send
      # \e[13;2u for Shift+Enter (configured in home/apps/iterm2).
      bind-key -n S-Enter send-keys Escape "[13;2u"
      # Enable focus events (required for Neovim/Vim auto-read)
      set -g focus-events on

      # True color passthrough for terminals that support it (incl. iTerm2)
      set -as terminal-features ',xterm*:RGB'
      set -ag terminal-overrides ',xterm*:Tc'
    '';
  };
}

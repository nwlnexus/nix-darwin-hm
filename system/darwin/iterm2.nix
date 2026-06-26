{
  # iTerm2 system-level configuration (all macOS hosts).
  #
  # The per-user "tmux" profile itself is defined in home/apps/iterm2 as an
  # iTerm2 Dynamic Profile. Here we install the app and wire up the bits that
  # live in iTerm2's preference domain rather than in a profile.

  homebrew = {
    casks = [ "iterm2" ];
    # `duti` is used to register iTerm2 as the default terminal handler
    # (see the duti activation in home/apps/iterm2/default.nix).
    brews = [ "duti" ];
  };

  system.defaults.CustomUserPreferences."com.googlecode.iterm2" = {
    # Make the managed Dynamic Profile the default for new windows/tabs.
    # A profile loaded from a Dynamic Profile cannot be set as default via
    # the GUI, but pointing the default-bookmark GUID at it works.
    #
    # IMPORTANT: must match `guid` in home/apps/iterm2/default.nix.
    "Default Bookmark Guid" = "8F9A1B2C-D3E4-4F56-A7B8-C9D0E1F2A3B4";

    # Hide the tmux -CC "gateway"/controller window after connecting, so
    # control-mode windows behave like native iTerm2 windows.
    AutoHideTmuxClientSession = true;

    # Don't nag with the "quit with running sessions" prompt on a tmux box.
    PromptOnQuit = false;
  };
}

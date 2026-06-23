{
  pkgs,
  lib,
  ...
}:

let
  # Fixed GUID for the managed "tmux" profile.
  #
  # IMPORTANT: this string must stay in sync with `Default Bookmark Guid`
  # in system/darwin/iterm2.nix, which is what makes this profile the
  # default for new windows/tabs.
  guid = "8F9A1B2C-D3E4-4F56-A7B8-C9D0E1F2A3B4";

  # Launch tmux in iTerm2 control-mode (-CC). iTerm2 detects control mode
  # from tmux's output stream, so wrapping in a login shell is fine and
  # ensures tmux is on PATH. `new-session -A -s main` attaches to the
  # `main` session if it exists, otherwise creates it.
  #
  # The -CC "gateway"/controller window is hidden via
  # AutoHideTmuxClientSession (see system/darwin/iterm2.nix).
  tmuxCommand = "/bin/zsh -l -c 'exec tmux -CC new-session -A -s main'";

  # Base profile attributes are version-controlled in ./profile.json and can
  # be regenerated from this host's live iTerm2 settings with:
  #   ./scripts/export-iterm-profile.sh
  baseProfile = builtins.fromJSON (lib.readFile ./profile.json);

  tmuxProfile = baseProfile // {
    "Name" = "tmux";
    "Guid" = guid;
    "Custom Command" = "Yes";
    "Command" = tmuxCommand;
  };

  dynamicProfiles = builtins.toJSON { Profiles = [ tmuxProfile ]; };
in

lib.mkIf pkgs.stdenv.isDarwin {
  # iTerm2 watches this directory and loads any JSON profiles it finds.
  home.file."Library/Application Support/iTerm2/DynamicProfiles/nix-tmux.json".text =
    dynamicProfiles;

  # Register iTerm2 as the default terminal handler. macOS has no single
  # "default terminal" setting, so we use `duti` (installed via Homebrew in
  # system/darwin/iterm2.nix) to claim the shell-script document types that
  # Finder / "open in terminal" actions use. Runs in the user's LaunchServices
  # context. Best-effort: skipped silently if duti isn't on PATH yet.
  home.activation.setIterm2DefaultTerminal = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    duti_bin=""
    for c in /opt/homebrew/bin/duti /usr/local/bin/duti; do
      [ -x "$c" ] && duti_bin="$c" && break
    done
    if [ -n "$duti_bin" ]; then
      run "$duti_bin" -s com.googlecode.iterm2 com.apple.terminal.shell-script all || true
      run "$duti_bin" -s com.googlecode.iterm2 public.shell-script all || true
    else
      echo "duti not found yet; skipping iTerm2 default-terminal association (re-run after first switch)"
    fi
  '';
}

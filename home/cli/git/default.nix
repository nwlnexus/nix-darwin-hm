{
  config,
  lib,
  pkgs,
  ...
}:

let
  workGitProfile = _config: {
    user = {
      email = "59927973+nwilliams-lucas@users.noreply.github.com";
      name = "Nigel Williams-Lucas";
      signingkey = "~/.ssh/gitlab-work-gl";
    };
    commit.gpgsign = true;
    gpg = {
      format = "ssh";
      ssh.program = "${pkgs.openssh}/bin/ssh-keygen";
    };
  };

  # Personal profile bypasses the 1Password SSH agent so unattended
  # agents can commit/push without biometric or desktop-app prompts.
  # The private key is materialized on disk by the
  # `fetchPersonalSSHKey` activation in home/apps/1password.nix.
  personalGitProfile = _config: {
    user = {
      email = "4689066+nwlucas@users.noreply.github.com";
      name = "Nigel Williams-Lucas";
      signingkey = "~/.ssh/id_ed25519";
    };
    commit.gpgsign = true;
    gpg = {
      format = "ssh";
      ssh.program = "${pkgs.openssh}/bin/ssh-keygen";
    };
  };

  aliases = {
    gs = "git status";
    ga = "git add .";
    gbr = "git branch -av";
    gbrn = "git !git branch | grep \"^*\" | awk '{ print $2 }'";
    gbrd = "git branch -D";
    gcm = "git commit -m";
    gco = "git checkout";
    gd = "git diff";
    gl = "git log";
    grs = "git restore";
    gsw = "git switch";
    gp = "git pull";
    gP = "git push";
  };
in

{
  imports = [
    ./delta.nix
    ./ui.nix
  ];

  home.packages = with pkgs; [
    git-ignore
  ];

  # Scope betterleaks' pre-commit secret scan to this repo's own committed
  # .githooks/pre-commit — deliberately NOT a global core.hooksPath, since
  # that would silently override any other repo's own hook mechanism (e.g.
  # moneta's husky-managed .husky, which sets its own local core.hooksPath
  # and would be unaffected by this either way, but a global default would
  # still change behavior for every other repo on the machine that doesn't
  # opt in via its own local override). Fail-soft: no-op if this repo isn't
  # checked out yet on a fresh host (mirrors gitnexusSetup below).
  home.activation.nixDarwinHmGitHooks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    REPO="${config.home.homeDirectory}/projects/personal/nix-darwin-hm"
    if [ -d "$REPO/.git" ]; then
      ${pkgs.git}/bin/git -C "$REPO" config core.hooksPath .githooks || true
    fi
  '';

  d.shell.aliases = aliases;

  programs = {
    # fish.shellAbbrs = aliases;

    git = {
      enable = true;

      settings.alias = {
        g = "!git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit --date=relative";
        l = "!f() { git log $* | grep '^commit ' | cut -f 2 -d ' '; }; f";
        r = "!git ls-files -z --deleted | xargs -0 git rm";
        addremove = "!git r && git add . --all";
        aliases = "!git config --list | grep 'alias\\.' | sed 's/alias\\.\\([^=]*\\)=\\(.*\\)/\\1\\ \t => \\2/' | sort";
        amend = "!git log -n 1 --pretty=tformat:%s%n%n%b | git commit -F - --amend";
        br = "branch -av";
        brname = "!git branch | grep \"^*\" | awk '{ print $2 }'";
        brdel = "branch -D";
        changes = "!f() { git log --pretty=format:'* %s' $1..$2; }; f";
        churn = ''
          !git log --all -M -C --name-only --format='format:' "$@" | sort | grep -v '^$' | uniq -c | sort | awk 'BEGIN {print "count,file"} {print $1 "," $2}'
        '';
        details = "log -n1 -p --format=fuller";
        export = ''
          archive -o latest.tar.gz -9 --prefix=latest/
        '';
        root = "rev-parse --show-toplevel";
        subup = "submodule update --init";
        tags = "tag -l";
        this = "!git init && git add . && git commit -m \"Initial commit.\"";
        trim = "!git reflog expire --expire=now --all && git gc --prune=now";
        unstage = "reset HEAD --";
      };

      settings.user.name = "Nigel Williams-Lucas";
      settings.user.email = "4689066+nwlucas@users.noreply.github.com";
      ignores = [ ".DS_Store" ];

      #Signing is done via the 1Password app
      signing = lib.mkIf (config.d.apps.onepassword.enable or false) {
        signByDefault = true;
        key = config.d.apps.onepassword.ssh.key;
      };

      includes =
        (map
          (condition: {
            inherit condition;
            contentSuffix = "gitconfig-work";
            contents = workGitProfile config;
          })
          [
            "gitdir:~/projects/work/"
            "hasconfig:remote.*.url:git@github.com-work/**"
            "hasconfig:remote.*.url:git@gitlab-work.com/**"
          ]
        )
        ++ (map
          (condition: {
            inherit condition;
            contentSuffix = "gitconfig-personal";
            contents = personalGitProfile config;
          })
          [
            "gitdir:~/projects/personal/"
          ]
        );

      settings.init.defaultBranch = "main";

      settings.gpg = {
        format = "ssh";
        ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
      };

      settings.log = {
        decorate = true;
        abbrevCommit = true;
      };

      settings.pull.rebase = false;

      # Autostash on "git pull ..."
      settings.merge.autoStash = true;
      settings.rebase.autoStash = true;

      settings.push.autoSetupRemote = true;

      # settings.http.sslCAInfo = "~/Cloudflare_CA.pem";
    };
  };
}

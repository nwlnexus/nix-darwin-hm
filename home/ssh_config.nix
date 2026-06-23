{ lib, user, ... }:
{
  programs.ssh = {
    enable = true;

    # home-manager 26.05 deprecated the implicit default-config values; opt out
    # and declare the defaults we want explicitly under settings."*".
    enableDefaultConfig = false;

    # 26.05 schema: `settings` is a DAG of blocks keyed by a stable label.
    # Block labels are kept identical to the previous `matchBlocks` keys so the
    # rendered ~/.ssh/config ordering (and ssh's first-match-wins behavior) is
    # unchanged. Each block's `Host` line is set via `header`, and options use
    # upstream OpenSSH directive names.
    settings = {
      "*" = {
        ForwardAgent = false;
        AddKeysToAgent = "yes";
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
        # Was previously a global `IdentitiesOnly yes` in extraConfig.
        IdentitiesOnly = true;
      };

      sshNWLNEXUS = {
        header = "Host *.ssh.nwlnexus.net";
        HostName = "%h";
        User = user;
        ProxyCommand = "/opt/homebrew/bin/cloudflared access ssh --hostname %n";
      };

      ghPersonal = {
        header = "Host github.com";
        HostName = "%h";
        User = "git";
        IdentityFile = "%d/.ssh/id_ed25519";
        IdentityAgent = "none";
        IdentitiesOnly = true;
      };

      ghDTLR = {
        header = "Host github.com-work";
        HostName = "github.com";
        User = "git";
        IdentityFile = "%d/.ssh/gitlab-work-gl";
        IdentityAgent = "none";
        IdentitiesOnly = true;
      };

      glabWork = {
        header = "Host gitlab-work.com";
        HostName = "%h";
        User = "git";
        IdentityFile = "%d/.ssh/gitlab-work-gl";
        IdentityAgent = "none";
        IdentitiesOnly = true;
      };

      dtlrSwitches = {
        header = "Host 10.254.0.*";
        User = "manager";
        ForwardAgent = true;
        PubkeyAcceptedKeyTypes = "ssh-rsa";
        HostKeyAlgorithms = "ssh-rsa";
        KexAlgorithms = "+diffie-hellman-group14-sha1";
      };

      sshDTLRONLINE = {
        header = "Host *.ssh.dtlronline.com";
        HostName = "%h";
        User = user;
        ProxyCommand = "/opt/homebrew/bin/cloudflared access ssh --hostname %n";
      };

      sshDTLRSTORES = lib.hm.dag.entryBefore [ "sshDTLRONLINE" ] {
        header = "Host *.ssh.store.dtlronline.com";
        HostName = "%h";
        User = "dtlr_it";
        ForwardAgent = true;
        ProxyCommand = "/opt/homebrew/bin/cloudflared access ssh --hostname %n";
      };

      tailScaleHosts = {
        header = "Host *.raptor-mimosa.ts.net";
        ForwardAgent = true;
        Compression = true;
      };

      onePassword = {
        header = ''Host * exec "test -z $SSH_TTY"'';
        IdentityAgent = ''"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"'';
      };
    };
  };
}

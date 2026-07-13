{ ... }:
{
  # Raise the launchd-inherited file-descriptor ceiling. The interactive
  # shell path already gets a large ulimit, but everything spawned OUTSIDE a
  # login shell — launchd agents, GUI apps, and every AI-agent/MCP-server
  # process they fork — inherits launchd's 256 soft default and starts
  # throwing EMFILE under fan-out workloads (observed alongside the
  # 2026-07-13 NWL-MMINI session storms; see modules/memory-watchdog).
  #
  # 65535 stays well under kern.maxfilesperproc (92160 on current macOS), so
  # no sysctl surgery is needed. The classic mechanism is the only supported
  # one: a boot-time daemon running `launchctl limit`, which adjusts the
  # limit every subsequent launchd child inherits. Processes already running
  # when it fires keep their old limit — effectively everything, after the
  # next reboot, since RunAtLoad fires before user sessions start.
  launchd.daemons.limit-maxfiles = {
    serviceConfig = {
      Label = "limit.maxfiles";
      ProgramArguments = [
        "/bin/launchctl"
        "limit"
        "maxfiles"
        "65535"
        "65535"
      ];
      RunAtLoad = true;
      ServiceIPC = false;
    };
  };
}

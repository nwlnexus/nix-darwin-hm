# d.agentHost (home/agent-host) for the Macs: per-account Claude Code / Codex dirs, Remote Control as launchd
# agents, the `agents` helper and the second-brain checkout. Off unless a host sets d.agentHost.enable in its
# home-manager user (olympus-sdk #690), so importing it changes nothing on the existing Macs.
{
  d.hm = [ ../../home/agent-host ];
}

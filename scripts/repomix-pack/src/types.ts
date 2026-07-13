export interface RepoTarget {
  owner: string;
  name: string;
  slug: string; // `${owner}/${name}`
  sshHost: string;
  originUrl: string; // git@${sshHost}:${owner}/${name}.git
  defaultBranch: string | null; // resolved lazily at checkout
  packPath: string;
  branch: string;
  group: string;
  graph: boolean;
  devClonePath: string;
}

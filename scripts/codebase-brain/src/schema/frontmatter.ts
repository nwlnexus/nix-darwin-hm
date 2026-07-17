import { z } from "zod";

export const NwlDocSchema = z.object({
  type: z.string().optional(),
  title: z.string(),
  description: z.string().optional(),
  tags: z.array(z.string()).optional(),
  resource: z.unknown().optional(),
  timestamp: z.string().optional(),
  docType: z.enum(["overview", "inventory", "cluster"]).or(z.string()),
  repo: z.string(),
  owner: z.string(),
  slug: z.string(),
  source: z.object({
    sha: z.string(),
    packHash: z.string(),
    graphDigest: z.string(),
    graphUri: z.string(),
    templateVersion: z.string(),
  }),
  brainPath: z.string(),
  status: z.literal("generated"),
});

export type NwlDoc = z.infer<typeof NwlDocSchema>;

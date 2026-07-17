import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { parseDigestsMarker } from "../digests";
import type { Digests, GraphRef, JobContext } from "../types";

const INTENT =
  "shared MCP canonical (parent C); Moneta refs only; mnemosyne convenience later" as const;

export function buildGraphRef(ctx: JobContext, graphDigest: string): GraphRef {
  const key = `${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/${ctx.sha}.tgz`;
  return {
    owner: ctx.owner,
    repo: ctx.repo,
    sha: ctx.sha,
    graphDigest,
    r2Uri: `r2://${ctx.r2Bucket}/${key}`,
    latestUri: `r2://${ctx.r2Bucket}/${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/latest`,
    intent: INTENT,
  };
}

export function graphRefOutPath(ctx: JobContext): string {
  return join(ctx.outDir, "graph-ref.json");
}

export function localDigestsMarkerPath(ctx: JobContext): string {
  return join(dirname(ctx.outDir), "latest-digests.json");
}

function shaObjectKey(ctx: JobContext): string {
  return `${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/${ctx.sha}.tgz`;
}

function latestObjectKey(ctx: JobContext): string {
  return `${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/latest`;
}

function latestJsonObjectKey(ctx: JobContext): string {
  return `${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/latest.json`;
}

export function latestDigestsObjectKey(ctx: JobContext): string {
  return `${ctx.r2Prefix}/${ctx.owner}/${ctx.repo}/latest-digests.json`;
}

export function hasR2Creds(): boolean {
  return Boolean(
    process.env.AWS_ACCESS_KEY_ID &&
      process.env.AWS_SECRET_ACCESS_KEY &&
      process.env.AWS_ENDPOINT_URL,
  );
}

function createS3Client(): S3Client {
  return new S3Client({
    region: "auto",
    endpoint: process.env.AWS_ENDPOINT_URL,
    credentials: {
      accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
      secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
    },
  });
}

async function uploadToR2(
  ctx: JobContext,
  tarballPath: string,
  graphRef: GraphRef,
): Promise<void> {
  const client = createS3Client();
  const body = await readFile(tarballPath);
  const refJson = JSON.stringify(graphRef, null, 2);

  await client.send(
    new PutObjectCommand({
      Bucket: ctx.r2Bucket,
      Key: shaObjectKey(ctx),
      Body: body,
      ContentType: "application/gzip",
    }),
  );

  await client.send(
    new PutObjectCommand({
      Bucket: ctx.r2Bucket,
      Key: latestObjectKey(ctx),
      Body: body,
      ContentType: "application/gzip",
    }),
  );

  await client.send(
    new PutObjectCommand({
      Bucket: ctx.r2Bucket,
      Key: latestJsonObjectKey(ctx),
      Body: refJson,
      ContentType: "application/json",
    }),
  );
}

async function uploadDigestsMarkerToR2(ctx: JobContext, digests: Digests): Promise<void> {
  const client = createS3Client();
  const body = JSON.stringify(digests, null, 2);
  await client.send(
    new PutObjectCommand({
      Bucket: ctx.r2Bucket,
      Key: latestDigestsObjectKey(ctx),
      Body: body,
      ContentType: "application/json",
    }),
  );
}

export async function publishDigestsMarker(
  ctx: JobContext,
  digests: Digests,
): Promise<{ localPath: string; r2Key: string }> {
  const localPath = localDigestsMarkerPath(ctx);
  const r2Key = latestDigestsObjectKey(ctx);
  const json = JSON.stringify(digests, null, 2);

  await mkdir(dirname(localPath), { recursive: true });
  await writeFile(localPath, json);

  if (!ctx.dryRun && hasR2Creds()) {
    try {
      await uploadDigestsMarkerToR2(ctx, digests);
    } catch (err) {
      console.warn(`failed to upload digests marker to R2 (${r2Key}):`, err);
    }
  }

  return { localPath, r2Key };
}

export async function fetchDigestsMarker(ctx: JobContext): Promise<Digests | null> {
  if (!hasR2Creds()) return null;
  try {
    const client = createS3Client();
    const res = await client.send(
      new GetObjectCommand({ Bucket: ctx.r2Bucket, Key: latestDigestsObjectKey(ctx) }),
    );
    const body = await res.Body?.transformToString();
    if (!body) return null;
    return parseDigestsMarker(JSON.parse(body));
  } catch {
    return null;
  }
}

export async function readLocalDigestsMarker(ctx: JobContext): Promise<Digests | null> {
  const path = localDigestsMarkerPath(ctx);
  const file = Bun.file(path);
  if (!(await file.exists())) return null;
  try {
    return parseDigestsMarker(await file.json());
  } catch {
    return null;
  }
}

export async function publishGraph(
  ctx: JobContext,
  tarballPath: string,
  graphDigest: string,
): Promise<GraphRef> {
  const graphRef = buildGraphRef(ctx, graphDigest);
  await mkdir(ctx.outDir, { recursive: true });
  await writeFile(graphRefOutPath(ctx), JSON.stringify(graphRef, null, 2));

  if (!ctx.dryRun && hasR2Creds()) {
    await uploadToR2(ctx, tarballPath, graphRef);
  }

  return graphRef;
}

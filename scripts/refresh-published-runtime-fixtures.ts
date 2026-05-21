#!/usr/bin/env tsx
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NUXIE_RIVE_MANIFEST_ARTIFACT_PATHS, NuxieRiveManifestV1Schema, type NuxieRiveManifestFontAssetV1, type NuxieRiveManifestV1 } from "@nuxie/models/schemas/nuxie-rive-manifest";
import { PublishIRSchema } from "@nuxie/models/schemas/publish-ir";
import type { ProjectSnapshot } from "@nuxie/core/projectdo/snapshot";
import { riveCompilerBackend } from "@nuxie/view-compiler/compiler-backends/rive";
import type { CompilerBackendArtifactFile } from "@nuxie/view-compiler/compiler-backends/types";

const __filename = fileURLToPath(import.meta.url);
const sdkRoot = path.resolve(path.dirname(__filename), "..");
const repoRoot = path.resolve(sdkRoot, "../..");
const fixtureRoot = path.join(sdkRoot, "Tests/FlowRuntimeHostApp/Fixtures");
const publishFixtureRoot = path.join(repoRoot, "tools/rive-compiler/fixtures/publish-path");
const defaultFontBytes = readFileSync(
  path.join(
    repoRoot,
    "apps/nuxie-dashboard/tests/visual/style-parity/fonts/InterVariable.ttf",
  ),
);
const fixtureBaseURLToken = "__NUXIE_FIXTURE_BASE_URL__";

type PublishPathFixture = {
  flowId: string;
  buildId: string;
  publishIr: unknown;
  snapshotArtifact?: {
    headSeq?: number;
    snapshot: unknown;
  };
};

type FontUpload = {
  key: string;
  body: Buffer;
  contentType?: string;
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const cloneJson = <T>(value: T): T =>
  JSON.parse(JSON.stringify(value)) as T;

const sha256Hex = (value: Buffer | string): string =>
  createHash("sha256").update(value).digest("hex");

const decodeArtifactFile = (
  artifact: string | CompilerBackendArtifactFile,
): Buffer => {
  if (typeof artifact === "string") {
    return Buffer.from(artifact, "utf8");
  }
  return Buffer.from(artifact.content, artifact.encoding ?? "utf8");
};

const safeFilePart = (value: string): string =>
  value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 96) || "asset";

const localFontPath = (asset: NuxieRiveManifestFontAssetV1): string =>
  path.posix.join(
    "assets/fonts",
    `${safeFilePart(`${asset.family}-${asset.weight}-${asset.style}`)}.${asset.format}`,
  );

const loadPublishPathFixture = (fixtureId: string): PublishPathFixture => {
  const fixturePath = path.join(publishFixtureRoot, `${fixtureId}.json`);
  const raw = JSON.parse(readFileSync(fixturePath, "utf8")) as PublishPathFixture & {
    schemaVersion?: string;
  };
  if (raw.schemaVersion !== "publish-path-fixture.v1") {
    throw new Error(`Invalid publish fixture schema for ${fixtureId}`);
  }
  return raw;
};

const textInputMotionFixture = (source: PublishPathFixture): PublishPathFixture => {
  const fixture = cloneJson(source);
  fixture.flowId = "flow_text_input_motion";
  fixture.buildId = "build_text_input_motion";

  if (isRecord(fixture.publishIr)) {
    fixture.publishIr.id = fixture.flowId;
    if (Array.isArray(fixture.publishIr.targets)) {
      for (const target of fixture.publishIr.targets) {
        if (isRecord(target)) {
          target.buildId = fixture.buildId;
        }
      }
    }
    if (isRecord(fixture.publishIr.flowArtifact)) {
      fixture.publishIr.flowArtifact.buildId = fixture.buildId;
    }
  }

  const snapshot = fixture.snapshotArtifact?.snapshot;
  const nodes =
    isRecord(snapshot) &&
    isRecord(snapshot.document) &&
    Array.isArray(snapshot.document.nodes)
      ? snapshot.document.nodes
      : null;
  if (!nodes) {
    throw new Error("Text input motion fixture source is missing document nodes");
  }

  nodes.push(
    {
      id: "animation.text_input_motion",
      projectId: "project_1",
      parentId: "screen_1::animation_tree",
      orderKey: "a",
      kind: "linear_animation",
      type: "linear_animation",
      data: {
        kind: "linear_animation",
        name: "Text Input Motion",
        fps: 60,
        duration: 600,
        speed: 1,
        loopValue: 0,
        keyedObjects: [
          {
            id: "keyed.email_input.text.x",
            objectKey: "artboard/screen_1/email_input/text",
            keyedProperties: [
              {
                id: "keyed.email_input.text.x.property",
                propertyKey: 13,
                valueType: "number",
                mixBehavior: "interpolate",
                keyFrames: [
                  {
                    id: "keyframe.email_input.text.x.0",
                    frame: 0,
                    valueType: "number",
                    value: 32,
                    interpolation: { type: "linear" },
                  },
                  {
                    id: "keyframe.email_input.text.x.600",
                    frame: 600,
                    valueType: "number",
                    value: 232,
                    interpolation: { type: "linear" },
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  );

  return fixture;
};

const canonicalPublishIrInput = (source: PublishPathFixture): unknown => {
  if (!isRecord(source.publishIr)) return source.publishIr;
  if (isRecord(source.publishIr.flowArtifact)) return source.publishIr;
  const bundle = isRecord(source.publishIr.bundle) ? source.publishIr.bundle : {};
  return {
    ...source.publishIr,
    flowArtifact: {
      url: typeof bundle.url === "string" ? bundle.url : "/preview/fixture",
      buildId: source.buildId,
      manifest: isRecord(bundle.manifest)
        ? bundle.manifest
        : {
            manifestVersion: 1,
            totalFiles: 0,
            totalSize: 0,
            contentHash: "pending",
            files: [],
          },
      status: "queued",
    },
  };
};

const rewriteFontAssets = (
  manifest: NuxieRiveManifestV1,
  fontUploads: FontUpload[],
  destinationRoot: string,
): NuxieRiveManifestV1 => ({
  ...manifest,
  assets: {
    ...manifest.assets,
    fonts: manifest.assets.fonts.map((fontAsset) => {
      const upload = fontUploads.find(
        (candidate) => sha256Hex(candidate.body) === fontAsset.sha256,
      );
      const body = upload?.body ?? defaultFontBytes;
      const localPath = localFontPath(fontAsset);
      const absolutePath = path.join(destinationRoot, localPath);
      mkdirSync(path.dirname(absolutePath), { recursive: true });
      writeFileSync(absolutePath, body);
      return {
        ...fontAsset,
        assetUrl: `${fixtureBaseURLToken}/${localPath}`,
      };
    }),
  },
});

const refreshFixture = async (params: {
  source: PublishPathFixture;
  sourceName: string;
  destinationFixtureId: string;
}): Promise<void> => {
  const source = params.source;
  const fontUploads: FontUpload[] = [];
  const compileResult = await riveCompilerBackend.compile({
    flowId: source.flowId,
    buildId: source.buildId,
    publishIr: PublishIRSchema.parse(canonicalPublishIrInput(source)),
    deps: {
      fontAssetStorage: {
        publicUrlBase: "https://cdn.test",
        objectExists: async () => false,
        putObject: async (key, body, options) => {
          fontUploads.push({
            key,
            body: Buffer.from(body),
            contentType: options?.contentType,
          });
        },
      },
      resolveRiveNativeFontAsset: async () => ({
        bytes: defaultFontBytes,
        contentType: "font/ttf",
        format: "ttf",
      }),
    },
    ...(source.snapshotArtifact
      ? {
          sourceArtifacts: {
            snapshot: {
              headSeq: source.snapshotArtifact.headSeq ?? 0,
              snapshot: source.snapshotArtifact.snapshot as ProjectSnapshot,
            },
          },
        }
      : {}),
  });

  const blockingDiagnostics = (compileResult.diagnostics ?? []).filter(
    (diagnostic) => diagnostic.isBlocking || diagnostic.severity === "error",
  );
  if (blockingDiagnostics.length > 0) {
    throw new Error(
      `Publish fixture ${params.sourceName} produced blocking diagnostics: ${JSON.stringify(blockingDiagnostics, null, 2)}`,
    );
  }
  if (compileResult.delivery.kind !== "artifact-files") {
    throw new Error(`Publish fixture ${params.sourceName} did not emit artifact files`);
  }

  const destinationRoot = path.join(fixtureRoot, params.destinationFixtureId);
  rmSync(destinationRoot, { recursive: true, force: true });
  mkdirSync(destinationRoot, { recursive: true });

  const manifestArtifact =
    compileResult.delivery.files[NUXIE_RIVE_MANIFEST_ARTIFACT_PATHS.manifest];
  if (typeof manifestArtifact !== "string") {
    throw new Error(`Publish fixture ${params.sourceName} did not emit a manifest`);
  }
  let manifest = NuxieRiveManifestV1Schema.parse(JSON.parse(manifestArtifact));

  const rivArtifact = compileResult.delivery.files[manifest.riv.path];
  if (!rivArtifact) {
    throw new Error(`Publish fixture ${params.sourceName} did not emit ${manifest.riv.path}`);
  }
  const rivBytes = decodeArtifactFile(rivArtifact);
  writeFileSync(path.join(destinationRoot, manifest.riv.path), rivBytes);

  for (const imageAsset of manifest.assets.images) {
    const imageArtifact = compileResult.delivery.files[imageAsset.path];
    if (!imageArtifact) {
      throw new Error(`Publish fixture ${params.sourceName} did not emit ${imageAsset.path}`);
    }
    const imagePath = path.join(destinationRoot, imageAsset.path);
    mkdirSync(path.dirname(imagePath), { recursive: true });
    writeFileSync(imagePath, decodeArtifactFile(imageArtifact));
  }

  manifest = rewriteFontAssets(manifest, fontUploads, destinationRoot);
  writeFileSync(
    path.join(destinationRoot, NUXIE_RIVE_MANIFEST_ARTIFACT_PATHS.manifest),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );

  console.log(
    `refreshed ${params.destinationFixtureId}: riv=${manifest.riv.sizeBytes} bytes sha=${manifest.riv.sha256}`,
  );
};

const main = async (): Promise<void> => {
  const visualViewContract = loadPublishPathFixture("visual-view-contract");
  await refreshFixture({
    source: visualViewContract,
    sourceName: "visual-view-contract",
    destinationFixtureId: "published-font",
  });
  await refreshFixture({
    source: textInputMotionFixture(visualViewContract),
    sourceName: "text-input-motion",
    destinationFixtureId: "text-input-motion",
  });
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
